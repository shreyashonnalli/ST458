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

source('training_functions.R')
source('feature_engineering_functions.R')
source('model_evaluation_functions.R')

################################################################################
# Data Preprocessing Temporary (THIS SECTION WILL BE DELETED IN FUTURE)
################################################################################

df <- read.csv('df_train.csv')                    # Read in csv
df$date <- as.Date(df$date, format = "%Y-%m-%d")  # Make the date column date instead of char
df <- df %>% arrange(symbol, date)                # Order according to symbol then date like in case study lecture

df_with_features <- as.data.frame(add_features(df, dV_kalman = 10, dW_kalman = 0.0001))
response_vars <- colnames(df_with_features %>% dplyr::select(matches("fwd")))
covariate_vars <- setdiff(colnames(df_with_features), c(response_vars, 'date', 'symbol', colnames(df_with_features %>% dplyr::select(matches("bwd")))))
categorical_vars <- c('quarter', 'month_of_year', 'day_of_week')

bunch(train_length, valid_length, lookahead, num_leaves,
      min_data_in_leaf, learning_rate, feature_fraction,
      bagging_fraction, num_iterations) %=% training_log[1, 1:9]


best_lgbm_params = list(
  objective = 'regression',
  num_iterations = num_iterations,
  num_leaves = num_leaves,
  learning_rate = learning_rate,
  feature_fraction = feature_fraction,
  bagging_fraction = bagging_fraction
)

#####################################################################################################
# FEATURE ENGINEERING FUNCTION - PASTE IN ENTIREITY OF feature_engineering_functions.R below
#####################################################################################################



###################################################################################################################################
# HYPERPARAMETERS - WE NEED TO MANUALLY TYPE AND UNCOMMENT BELOW WHILE SUBMITTING, BUT FOR NOW AUTO FROM training_log above.
###################################################################################################################################
# column variable names from df we're going to use to train - NEED TO MANUALLY TYPE OUT
# response_var ->
# covariate_vars ->
# categorical_vars -> c('quarter', 'month_of_year', 'day_of_week')
# 
# 
# # Time interval related hyperparams
# train_length ->
# valid_length ->
# lookahead ->
# 
# # LGBM related hyperparams
# num_leaves ->
# min_data_in_leaf ->
# learning_rate ->
# feature_fraction ->
# bagging_fraction ->
# num_iterations ->

# best_lgbm_params = list(
#   objective = 'regression',
#   num_iterations = num_iterations,
#   num_leaves = num_leaves,
#   learning_rate = learning_rate,
#   feature_fraction = feature_fraction,
#   bagging_fraction = bagging_fraction
# )

#####################################################################################################
# HELPER FUNCTIONS - initialise_data
#####################################################################################################

create_list_df_format <- function(data_preprocessed, response_var){
  # Get the df into the form of a list with each index being a unique date.
  df_list <- split(data_preprocessed, data_preprocessed$date)
  df_list <- lapply(df_list, function(sub_df){
    tmp <- matrix(NA, 100, length(colnames(data_preprocessed)) - 2)
    rownames(tmp) <- sub_df$symbol
    colnames(tmp) <- colnames(sub_df)[-c(1, 2)]
    tmp[sub_df$symbol, ] <- as.matrix(sub_df[, -c(1, 2)])
    tmp[, response_var] <- NA
    return(tmp)
  })
  
  for (i in 1:train_length){
    df_list[[i]][, response_var] <- df_list[[i+5]][, response_var]
  }
  return(df_list)
}


#####################################################################################################
# IMPORTANT: FUNCTIONS TO SUBMIT
#####################################################################################################

# Input has to be all data in the training set.
# External variables - 
  # train_length, lookahead
  # need to set these inside the function for modularity because they were implemented as global vars in the tutorial
initialise_state <- function(data){
  # train_length <- NEED TO SET IN FUNCTION FOR MODULARITY
  # lookahead <- NEED TO SET FUNCTION FOR MODULARITY
  
  unique_dates <- sort(as.Date(unique(data$date)))
  dates_recent <- tail(unique_dates, train_length + lookahead)

  #Get recent most 402+21=423 dates 
  data <- data[data$date %in% dates_recent, ]
  data_preprocessed <- as.data.frame(add_features(data, dV_kalman = 10, dW_kalman = 0.0001))
  
  day_idx <- 0
  
  # Get the df into the form of a list with each index being a unique date.
  # df_list <- split(data_preprocessed, data_preprocessed$date)
  # df_list <- lapply(df_list, function(sub_df){
  #   tmp <- matrix(NA, 100, 66)
  #   rownames(tmp) <- sub_df$symbol
  #   colnames(tmp) <- colnames(sub_df)[-c(1, 2)]
  #   tmp[sub_df$symbol, ] <- as.matrix(sub_df[, -c(1, 2)])
  #   tmp[, 'simple_returns_fwd_day_5'] <- NA
  #   return(tmp)
  # })
  
  # for (i in 1:train_length){
  #   df_list[[i]][, 'simple_returns_fwd_day_5'] <- df_list[[i+5]][, 'simple_returns_bwd_day_5']
  # }
  
  df_list <- create_list_df_format(data_preprocessed, 'simple_returns_fwd_day_5')
   
  positions <- matrix(0, lookahead, 100)
  colnames(positions) <- rownames(df_list[[1]])
  
  
  
  state <- list(day_idx=day_idx, 
                positions=positions, 
                df_recent=df_list, 
                model=NULL,
                data = data[data$date %in% tail(unique_dates, 35), ])
  
  return(state)
}




# Input has to be the most 
# External variables - 
  # train_length, lookahead, covariate_vars, categorical_vars, best_lgbm_params
  # need to set these inside the function for modularity because they were implemented as global vars in the tutorial
trading_algorithm <- function(new_data, state){
  # train_length <- NEED TO SET
  # lookahead <- NEED TO SET
  # covariate_vars <- NEED TO SET
  # categorical_vars <- NEED TO SET
  # best_lgbm_params <- NEED TO SET
  bunch(day_idx, positions, df_recent, model, data) %=% state
  
  new_unique_date <- sort(as.Date(unique(new_data$date)))
  data_with_new_data <- rbind(data, new_data)
  data_with_new_data <- data_with_new_data %>% arrange(symbol, date)
  
  data_with_new_data_with_features <- as.data.frame(add_features(data_with_new_data, dV_kalman = 10, dW_kalman = 0.0001))
  new_data_with_features <- data_with_new_data_with_features[data_with_new_data_with_features$date %in% new_unique_date, ]
  day_idx = day_idx + 1
  
  df_recent[[1]] <- NULL
  
  #Convert new data to a matrix and append it to df_recent
  tmp <- matrix(NA, 100, length(colnames(new_data_with_features)) - 2)
  rownames(tmp) <- rownames(tail(df_recent, 1)[[1]])
  colnames(tmp) <- colnames(tail(df_recent, 1)[[1]])
  tmp[new_data_with_features$symbol, ] <- as.matrix(new_data_with_features[, -c(1,2)])
  new_date <- as.character(new_data_with_features$date[1])
  df_recent[[new_date]] <- tmp
  
  # Update the future returns of the past variable
  df_recent[[train_length]][, 'simple_returns_fwd_day_5'] <- df_recent[[new_date]][, 'simple_returns_bwd_day_5']
  
  
  if (day_idx %% valid_length == 1){
    train_mx <- do.call(rbind, df_recent[1:train_length])
    dtrain <- lgb.Dataset(data=train_mx[, covariate_vars], 
                          label=train_mx[, 'simple_returns_fwd_day_5'],
                          categorical_feature=categorical_vars)
    model <- lgb.train(params = best_lgbm_params, data = dtrain, verbose=-1)
  }
  
  preds <- predict(model, df_recent[[new_date]][, covariate_vars])
  
  position_to_close <- positions[lookahead, ]
  
  positions[2:lookahead, ] <- positions[1:(lookahead-1), ]
  
  is_short <- rank(preds) <= 5
  is_long <- rank(preds) > 95
  positions[1, ] <- 0
  positions[1, is_short] <- -1/100
  positions[1, is_long] <- 1/100
  
  trades <- positions[1, ] - position_to_close
  
  
  unique_recent_dates <- sort(as.Date(unique(data_with_new_data$date)))
  
   
  new_state <- list(day_idx=day_idx, 
                    positions=positions, 
                    df_recent=df_recent, 
                    model=model, 
                    data=data_with_new_data[data_with_new_data$date %in% tail(unique_recent_dates, 35), ])
  
  
  return(list(trades=trades, new_state=new_state))
}




#####################################################################################################
# NO NEED FOR THE BELOW FUNCTION BECAUSE WE'RE MEANT TO USE walk_forward.R (Kept just in case)
#####################################################################################################


# mask_response <- function(data){
#   response_vars <- colnames(data %>% dplyr::select(matches("fwd")))
#   data[, response_vars] <- NA
#   return(data)
# }
# walk_forward <- function(strategy, initialiser, df_train, df_test, df_with_features_test){
#   state <- initialiser(mask_response(df_train))
#   unique_test_dates <- sort(unique(df_test$date))
#   n_test_dates <- length(unique_test_dates)
#   position <- rep(0, 50)
#   daily_pnl <- rep(0, n_test_dates)
#   
#   for (i in 1: n_test_dates){
#     new_data <- df_test[df_test$date == unique_test_dates[i], ]
#     new_data <- sort_data_frame(new_data, 'symbol')
#     bunch(trades, state) %=% strategy(mask_response(new_data), state)
#     position <- position + trades
#     
#     new_data_with_features <- df_with_features_test[df_with_features_test$date == unique_test_dates[i], ]
#     new_data_with_features <- sort_data_frame(new_data_with_features, 'symbol')
#     
#     r1fwd <- new_data_with_features[, 'simple_returns_fwd_day_1']
#     daily_pnl[i] <- log(1 + sum(position * r1fwd))
#     printPercentage(i, n_test_dates)
#   }
#   # We should lag because trades are executed at the end of the day
#   daily_pnl <- lag(daily_pnl)
#   daily_pnl[1] <- 0
#   
#   wealth <- exp(cumsum(daily_pnl)) / 1
#   
#   return(list(wealth = wealth, daily_pnl = daily_pnl))
# }
# wealth_and_pnl <- walk_forward(trading_algorithm, initialise_state, df[df$date < as.Date('2013-01-01'), ], df[df$date >= as.Date('2013-01-01'), ], df_with_features[df_with_features$date >= as.Date('2013-01-01'), ])
# performance_evaluation_of_wealth(wealth_and_pnl$wealth, wealth_and_pnl$daily_pnl, 0.03)



