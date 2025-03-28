library(putils)
library(tidyverse)
library(xts)
library(dplyr)
library(R.utils)
library(lightgbm)
library(reshape2)
library(quantmod)
library(zoo)
library(ggplot2)
library(TTR)
library(urca)
library(dplyr)


source("training_functions.R")
source("feature_engineering_functions.R")
source("model_evaluation_functions.R")

################################################################################
# Data Preprocessing & Cointegration
################################################################################

df <- read.csv("df_train.csv") # Read in csv
df$date <- as.Date(df$date, format = "%Y-%m-%d") # Make the date column date instead of char
df <- df %>% arrange(symbol, date) # Order according to symbol then date like in case study lecture

df_wide <- df %>% # convert to wide so that each column = stock closing price over time
  dplyr::select(date, symbol, close) %>% # close price
  tidyr::pivot_wider(names_from = symbol, values_from = close)
df_wide <- as.data.frame(df_wide)

rownames(df_wide) <- df_wide$date
df_wide$date <- NULL

df_wide <- df_wide[, sapply(df_wide, is.numeric), drop = FALSE]

df_wide <- df_wide %>% mutate(across(everything(), ~ zoo::na.locf(.x, na.rm = FALSE))) # if price is NA replace w last known price (cannot have NA for Johansen)

# Johansen Test & VECM
num_assets_per_group <- 5
window_size <- 252 # rolling window of one year so that we only use past data
step_size <- 5 # update weekly
max_lag <- 2 # number of residual lags to compute

df_wide <- df %>%
  select(date, symbol, close) %>%
  pivot_wider(names_from = symbol, values_from = close) %>%
  arrange(date)

df_wide <- df_wide %>%
  mutate(across(-date, ~ zoo::na.locf(.x, na.rm = FALSE))) %>%
  column_to_rownames("date")

all_lagged_residuals <- list()
all_dates <- as.Date(rownames(df_wide))
asset_names <- colnames(df_wide)

# loop through asset groups
for (g in seq(1, length(asset_names), by = num_assets_per_group)) {
  asset_subset <- asset_names[g:min(g + num_assets_per_group - 1, length(asset_names))]

  for (i in seq(window_size + max_lag, length(all_dates), by = step_size)) {
    date_range <- all_dates[(i - window_size - max_lag + 1):i]
    current_date <- all_dates[i]

    df_subset <- df_wide[as.character(date_range), asset_subset, drop = FALSE]
    if (anyNA(df_subset)) next

    # Johansen Test
    johansen_test <- tryCatch(
      ca.jo(df_subset, type = "trace", ecdet = "none", K = 2),
      error = function(e) NULL
    )
    if (is.null(johansen_test)) next

    trace_stat <- johansen_test@teststat
    crit_vals <- johansen_test@cval
    significant_ranks <- which(trace_stat > crit_vals[, 2]) # 5% level
    r <- ifelse(length(significant_ranks) == 0, 0, length(significant_ranks))

    # skip if no cointegration
    if (r == 0) next

    vecm_model <- cajorls(johansen_test, r = r)
    resids <- as.data.frame(residuals(vecm_model$rlm))

    # only take residuals for the final row (current prediction day)
    current_resid <- tail(resids, 1)
    current_resid$date <- current_date
    colnames(current_resid)[1:ncol(resids)] <- paste0(asset_subset[1:ncol(resids)], "_residual")

    all_lagged_residuals[[length(all_lagged_residuals) + 1]] <- current_resid
  }
}
head(all_lagged_residuals)

# merge residuals and reshape
residuals_df <- bind_rows(all_lagged_residuals)

residuals_long <- residuals_df %>%
  pivot_longer(-date, names_to = "symbol", values_to = "residual") %>%
  mutate(symbol = gsub("_residual", "", symbol))

residuals_long_clean <- residuals_long %>%
  filter(!is.na(residual)) %>%
  distinct(date, symbol, .keep_all = TRUE)

residuals_lagged <- residuals_long_clean %>%
  arrange(symbol, date) %>%
  group_by(symbol) %>%
  mutate(
    residual_lag1 = lag(residual, 1),
  ) %>%
  ungroup() %>%
  select(date, symbol, residual_lag1)

residuals_lagged <- residuals_lagged %>% # standardizing residuals
  group_by(symbol) %>%
  mutate(
    residual_lag1_z = as.numeric(scale(residual_lag1))
  ) %>%
  ungroup()

df_with_residuals <- df %>%
  left_join(residuals_lagged %>% select(date, symbol, residual_lag1_z), by = c("date", "symbol"))

df_with_residuals[df_with_residuals$symbol == "ACTS" & df_with_residuals$date == as.Date("2011-01-11"), ] # check to see if works

df_with_features <- add_features(df, dV_kalman = 10, dW_kalman = 0.0001)
df_with_features <- as.data.frame(df_with_features)
# df_with_features <- get_bottom_n_liquid_assets(df_with_features, 20)

head(df_with_features)

tickers <- unique(df$symbol)

################################################################################
# LGBM
################################################################################

response_vars <- colnames(df_with_features %>% dplyr::select(matches("fwd")))
covariate_vars <- setdiff(colnames(df_with_features), c(response_vars, "date", "symbol")) # 'residual', 'residual_lag1', 'residual_lag2'
covariate_vars <- c("open", "high", "low", "close", "volume") # THIS LINE IS USED TO TEST WITH NO FEATURES
# Deliberately leaking in data to see how it performs.
# Note: We get 160% rate of return!

categorical_vars <- c("month_of_year", "day_of_week") # quarter
categorical_vars <- c()

df_with_features_train <- df_with_features[df_with_features$date < as.Date("2013-01-01"), ]
df_with_features_test <- df_with_features[df_with_features$date >= as.Date("2013-01-01"), ]

# Hyper-parameter combination grid
param_df <- expand.grid(
  train_length = c(252, 252 * 2, 126),
  valid_length = c(21, 63),
  lookahead = c(5),
  num_leaves = c(5, 10, 50),
  min_data_in_leaf = c(250, 1000),
  learning_rate = c(0.01, 0.03, 0.1),
  feature_fraction = c(0.3, 0.6, 0.95),
  bagging_fraction = c(0.3, 0.6, 0.95),
  num_iterations = c(30, 200)

  #   # atr_window = c(14, 20, 50),
  #   # sma_window = c(10, 20, 50, 200),
  #   # ema_window = c(10, 20, 50, 200),
  #   # rsi_window = c(7, 14, 21),
  #   # macd_fast = c(12, 26),
  #   # macd_slow = c(26, 50)
)
#
# param_df <- expand.grid(
#   train_length = c(252, 252*2),
#   valid_length = c(21, 63),
#   lookahead = c(5),
#   num_leaves = c(50, 75, 100),
#   min_data_in_leaf = c(250,1000),
#   learning_rate = c(0.1, 0.15, 0.2),
#   feature_fraction = c(0.3,0.6,0.95),
#   bagging_fraction = c(0.3,0.6,0.95),
#   num_iterations = c(200, 250, 300)
#
#   # atr_window = c(14, 20, 50),
#   # sma_window = c(10, 20, 50, 200),
#   # ema_window = c(10, 20, 50, 200),
#   # rsi_window = c(7, 14, 21),
#   # macd_fast = c(12, 26),
#   # macd_slow = c(26, 50)
# )


param_df <- expand.grid(
  train_length = c(252, 252 * 2),
  valid_length = c(21, 63),
  lookahead = c(5),
  num_leaves = c(50, 75, 100),
  min_data_in_leaf = c(250, 1000),
  learning_rate = c(0.1, 0.15, 0.2, 0.5),
  feature_fraction = c(0.6, 0.95, 1.00),
  bagging_fraction = c(0.3, 0.6, 0.95),
  num_iterations = c(200, 250, 300),
  number_stocks_chosen = c(20, 50, 80, 100)
)

training_log <- hyperparameter_grid_training_lgbm(df_with_features_train, param_df, 10, covariate_vars, categorical_vars)
training_log <- sort_data_frame(training_log, "ic", decreasing = T)
head(training_log)
################################################################################
# Evaluation of LGBM with some plots
################################################################################

lgbm_features_effects_plot(df_with_features_train, covariate_vars, categorical_vars, training_log[1, ])
dev.off()
lgbm_hyperparameters_marginal_effect_plot(training_log)

################################################################################
# Back-testing a trading algorithm on the validation set.
################################################################################

hyperparameters <- training_log[1, ]

bottom_liquid_covariates <- unique(get_bottom_n_liquid_assets(df_with_features_train, hyperparameters[10]$number_stocks_chosen)$symbol)

df_with_features_filtered <- get_filtered_given_symbols(df_with_features, bottom_liquid_covariates)
df_with_features_train_filtered <- get_filtered_given_symbols(df_with_features_train, bottom_liquid_covariates)
df_with_features_test_filtered <- get_filtered_given_symbols(df_with_features_test, bottom_liquid_covariates)

y_preds <- lgbm_get_validation_set_predictions(df_with_features_filtered, df_with_features_test_filtered, covariate_vars, categorical_vars, hyperparameters)
# This implements basic strategy of buy top 5 highest returns and short bottom 5 lowest returns
combined_position <- lgbm_get_positions_based_on_predictions(df_with_features_filtered, df_with_features_test_filtered, y_preds, hyperparameters)
# This implements Kelly Criterion
combined_position_kelly <- lgbm_get_positions_based_on_kelly(df_with_features_filtered, df_with_features_test_filtered, y_preds, hyperparameters)
combined_position_min_var <- lgbm_get_positions_based_on_wmv(df_with_features_filtered, df_with_features_test_filtered, y_preds, hyperparameters)
combined_position_mkt <- lgbm_get_positions_based_on_wmkt(df_with_features_filtered, df_with_features_test_filtered, y_preds, hyperparameters)

dev.off()
wealth_and_pnl <- get_pnl_based_on_position(df_with_features_filtered, df_with_features_test_filtered, combined_position)

performance_evaluation_of_wealth(wealth_and_pnl$wealth, wealth_and_pnl$daily_pnl, 0.03)


# Pruning Features:
# checking for highly correlated features (to remove redundant ones)
numeric_covariates <- df_with_features %>%
  dplyr::select(all_of(covariate_vars)) %>%
  dplyr::select(where(is.numeric))
cor_matrix <- cor(numeric_covariates, use = "pairwise.complete.obs")
heatmap(cor_matrix, symm = TRUE)

get_highly_correlated_pairs <- function(cor_matrix, threshold = 0.95) {
  cor_pairs <- which(abs(cor_matrix) > threshold, arr.ind = TRUE)
  cor_pairs <- cor_pairs[cor_pairs[, 1] < cor_pairs[, 2], , drop = FALSE] # remove duplicates
  data.frame(
    feature_1 = rownames(cor_matrix)[cor_pairs[, 1]],
    feature_2 = colnames(cor_matrix)[cor_pairs[, 2]],
    correlation = cor_matrix[cor_pairs]
  )
}

redundant_pairs <- get_highly_correlated_pairs(cor_matrix, threshold = 0.95)
as.data.frame(redundant_pairs)
redundant_pairs <- redundant_pairs %>%
  arrange(desc(correlation))
print(redundant_pairs)


# least important features (function added to training_functions.R)
least_important <- extract_least_important_features(
  df = df_with_features_train,
  training_log = training_log,
  covariate_vars = covariate_vars,
  categorical_vars = categorical_vars,
  response_var = "simple_returns_fwd_day_5"
)
least_important
