module Adapter.HTTP.API
       ( main
       ) where

import ClassyPrelude hiding (delete)

import Core.Types
import Core.Services
import Control.Monad.Except
import Web.Scotty.Trans
import Network.HTTP.Types.Status
import Network.Wai (Response)
import Network.Wai.Handler.WarpTLS (runTLS, tlsSettings)
import Network.Wai.Handler.Warp (defaultSettings, setPort)
import qualified Text.Digestive.Form as DF
import qualified Text.Digestive.View as DF
import qualified Text.Digestive.Types as DF
import qualified Text.Digestive.Aeson as DF
import Text.Digestive.Form ((.:))
import Text.Regex
import Network.Wai.Middleware.Cors
import Data.Aeson (ToJSON)

import System.Environment

type App r m = (AllRepo m, MonadIO m)

main :: (App r m) => (m Response -> IO Response) -> IO ()
main runner = do
  port <- acquirePort
  mayTLSSetting <- acquireTLSSetting
  case mayTLSSetting of
    Nothing ->
      scottyT port runner routes
    Just tlsSetting -> do
      app <- scottyAppT runner routes
      runTLS tlsSetting (setPort port defaultSettings) app
  where
    acquirePort = do
      port <- fromMaybe "" <$> lookupEnv "PORT"
      return . fromMaybe 3000 $ readMay port
    acquireTLSSetting = do
      env <- (>>= readMay) <$> lookupEnv "ENABLE_HTTPS"
      let enableHttps = fromMaybe True env
      return $ if enableHttps
        then Just $ tlsSettings "secrets/tls/certificate.pem" "secrets/tls/key.pem"
        else Nothing



-- * Routing

routes :: (App r m) => ScottyT LText m ()
routes = do
  -- middlewares

  middleware $ cors $ const $ Just simpleCorsResourcePolicy
    { corsRequestHeaders = "Authorization":simpleHeaders
    , corsMethods = "PUT":"DELETE":simpleMethods
    }
  options (regex ".*") $ return ()

  -- err 
  
  defaultHandler unknownErrorHandler

  -- users

  post "/api/users/login" $ do
    req <- parseJsonBody ("user" .: authForm)
    result <- stopIfError userErrorHandler $ login req
    json $ UserWrapper result

  post "/api/users" $ do
    req <- parseJsonBody ("user" .: registerForm)
    result <- stopIfError userErrorHandler $ register req
    json $ UserWrapper result

  get "/api/user" $ do
    curUser <- requireUser
    result <- stopIfError userErrorHandler $ getUser curUser
    json $ UserWrapper result

  put "/api/user" $ do
    curUser <- requireUser
    req <- parseJsonBody ("user" .: updateUserForm)
    result <- stopIfError userErrorHandler $ updateUser curUser req
    json $ UserWrapper result


  -- profiles

  get "/api/profiles/:username" $ do
    curUser <- optionalUser
    username <- param "username"
    result <- stopIfError userErrorHandler $ getProfile curUser username
    json $ ProfileWrapper result

  post "/api/profiles/:username/follow" $ do
    curUser <- requireUser
    username <- param "username"
    result <- stopIfError userErrorHandler $ followUser curUser username
    json $ ProfileWrapper result

  delete "/api/profiles/:username/follow" $ do
    curUser <- requireUser
    username <- param "username"
    result <- stopIfError userErrorHandler $ unfollowUser curUser username
    json $ ProfileWrapper result


  -- articles

  get "/api/articles" $ do
    curUser <- optionalUser
    pagination <- parsePagination
    articleFilter <- parseArticleFilter
    result <- lift $ getArticles curUser articleFilter pagination
    json $ ArticlesWrapper result (length result)

  get "/api/articles/feed" $ do
    curUser <- requireUser
    pagination <- parsePagination
    result <- lift $ getFeed curUser pagination
    json $ ArticlesWrapper result (length result)

  get "/api/articles/:slug" $ do
    curUser <- optionalUser
    slug <- param "slug"
    result <- stopIfError articleErrorHandler $ getArticle curUser slug
    json $ ArticleWrapper result

  post "/api/articles" $ do
    curUser <- requireUser
    req <- parseJsonBody ("article" .: createArticleForm)
    result <- stopIfError articleErrorHandler $ createArticle curUser req
    json $ ArticleWrapper result

  put "/api/articles/:slug" $ do
    curUser <- requireUser
    slug <- param "slug"
    req <- parseJsonBody ("article" .: updateArticleForm)
    result <- stopIfError articleErrorHandler $ updateArticle curUser slug req
    json $ ArticleWrapper result

  delete "/api/articles/:slug" $ do
    curUser <- requireUser
    slug <- param "slug"
    stopIfError articleErrorHandler $ deleteArticle curUser slug
    json $ asText ""


  -- favorites

  post "/api/articles/:slug/favorite" $ do
    curUser <- requireUser
    slug <- param "slug"
    result <- stopIfError articleErrorHandler $ favoriteArticle curUser slug
    json $ ArticleWrapper result

  delete "/api/articles/:slug/favorite" $ do
    curUser <- requireUser
    slug <- param "slug"
    result <- stopIfError articleErrorHandler $ unfavoriteArticle curUser slug
    json $ ArticleWrapper result


  -- comments

  post "/api/articles/:slug/comments" $ do
    curUser <- requireUser
    slug <- param "slug"
    req <- parseJsonBody ("comment" .: "body" .: DF.text Nothing)
    result <- stopIfError commentErrorHandler $ addComment curUser slug req
    json $ CommentWrapper result

  delete "/api/articles/:slug/comments/:id" $ do
    curUser <- requireUser
    slug <- param "slug"
    cId <- param "id"
    stopIfError commentErrorHandler $ delComment curUser slug cId
    json $ asText ""
  
  get "/api/articles/:slug/comments" $ do
    curUser <- optionalUser
    slug <- param "slug"
    result <- stopIfError commentErrorHandler $ getComments curUser slug
    json $ CommentsWrapper result
  

  -- tags

  get "/api/tags" $ do
    result <- lift getTags
    json $ TagsWrapper result

  
  -- health

  get "/api/health" $
    json True


-- * Utils
  
parsePagination :: (ScottyError e, Monad m) => ActionT e m Pagination
parsePagination = do
  limit <- param "limit" `rescue` const (return 20)
  offset <- param "offset" `rescue` const (return 0)
  return $ Pagination limit offset

mayParam :: (ScottyError e, Monad m) => LText -> ActionT e m (Maybe Text)
mayParam name = (Just <$> param name) `rescue` const (return Nothing)
  
parseArticleFilter :: (ScottyError e, Monad m) => ActionT e m ArticleFilter
parseArticleFilter = ArticleFilter <$> mayParam "tag" <*> mayParam "author" <*> mayParam "favorited"

parseJsonBody :: (MonadIO m) => DF.Form [Text] m a -> ActionT LText m a
parseJsonBody form = do
  val <- jsonData `rescue` inputMalformedJSONErrorHandler
  (v, result) <- lift $ DF.digestJSON form val
  case result of
    Nothing -> inputErrorHandler v
    Just x -> return x

getCurrentUser :: (App r m) => ActionT LText m (Either TokenError CurrentUser)
getCurrentUser = do
  mayHeaderVal <- header "Authorization"
  runExceptT $ do
    headerVal <- ExceptT $ pure mayHeaderVal `orThrow` TokenErrorNotFound
    let token = toStrict $ drop 6 headerVal
    ExceptT $ lift $ resolveToken token

requireUser :: (App r m) => ActionT LText m CurrentUser
requireUser = do
  result <- getCurrentUser
  stopIfError tokenErrorHandler (pure result)

optionalUser :: (App r m) => ActionT LText m (Maybe CurrentUser)
optionalUser =
  either (const Nothing) Just <$> getCurrentUser

stopIfError :: (Monad m, ScottyError e') => (e -> ActionT e' m ()) -> m (Either e a) -> ActionT e' m a
stopIfError errHandler action = do
  result <- lift action
  case result of
    Left e -> do 
      errHandler e
      finish
    Right a ->
      return a


-- * Errors

inputErrorHandler :: (ScottyError e, Monad m) => DF.View [Text] -> ActionT e m a
inputErrorHandler v = do
  let errs = mapFromList $ map (first (intercalate "." . drop 1)) $ DF.viewErrors v :: InputViolations
  status status422
  json $ ErrorsWrapper errs
  finish

inputMalformedJSONErrorHandler :: (ScottyError e, Monad m) => err -> ActionT e m a
inputMalformedJSONErrorHandler _ = do
  status status422
  json $ ErrorsWrapper $ asText "Malformed JSON payload"
  finish

tokenErrorHandler :: (ScottyError e, Monad m) => TokenError -> ActionT e m ()
tokenErrorHandler e = do
  status status401
  json e

userErrorHandler :: (ScottyError e, Monad m) => UserError -> ActionT e m ()
userErrorHandler err = case err of
  UserErrorBadAuth _ -> do
    status status400
    json err
  UserErrorNotFound _ -> do
    status status404
    json err
  UserErrorNameTaken _ -> do
    status status400
    json err
  UserErrorEmailTaken _ -> do
    status status400
    json err

articleErrorHandler :: (ScottyError e, Monad m) => ArticleError -> ActionT e m ()
articleErrorHandler err = case err of
  ArticleErrorNotFound _ -> do
    status status404
    json err
  ArticleErrorNotAllowed _ -> do
    status status403
    json err

commentErrorHandler :: (ScottyError e, Monad m) => CommentError -> ActionT e m ()
commentErrorHandler err = case err of
  CommentErrorNotFound _ -> do
    status status404
    json err
  CommentErrorSlugNotFound _ -> do
    status status404
    json err
  CommentErrorNotAllowed _ -> do
    status status403
    json err

unknownErrorHandler :: (ScottyError e, Monad m, ToJSON err) => err -> ActionT e m ()
unknownErrorHandler str = do
  status status500
  json str


-- * Request deserialization & validation

minLength :: MonoFoldable a => Int -> a -> DF.Result Text a
minLength n str = if length str >= n then DF.Success str else DF.Error $ "Minimum length is " <> tshow n

matchesRegex :: v -> String -> Text -> DF.Result v Text
matchesRegex errMsg regexStr str =
  if isJust . matchRegex (mkRegexWithOpts regexStr True True) . unpack $ str
    then DF.Success str
    else DF.Error errMsg

emailValidation :: Text -> DF.Result [Text] Text
emailValidation = DF.conditions [matchesRegex "Not a valid email" "^[a-zA-Z0-9\\.\\+\\-]+@[a-zA-Z0-9]+\\.[a-zA-Z0-9]+$"]

usernameValidation :: Text -> DF.Result [Text] Text
usernameValidation = DF.conditions [minLength 3, matchesRegex "Should be alphanumeric" "^[a-zA-Z0-9]+$"]

passwordValidation :: Text -> DF.Result [Text] Text
passwordValidation = DF.conditions [minLength 5]

authForm :: (Monad m) => DF.Form [Text] m Auth
authForm = Auth <$> "email" .: DF.validate emailValidation (DF.text Nothing)
                <*> "password" .: DF.validate passwordValidation (DF.text Nothing)
                
registerForm :: (Monad m) => DF.Form [Text] m Register
registerForm = Register <$> "username" .: DF.validate usernameValidation (DF.text Nothing)
                        <*> "email" .: DF.validate emailValidation (DF.text Nothing)
                        <*> "password" .: DF.validate passwordValidation (DF.text Nothing)
                        
updateUserForm :: (Monad m) => DF.Form [Text] m UpdateUser
updateUserForm = UpdateUser <$> "email" .: DF.validateOptional emailValidation (DF.optionalText Nothing)
                            <*> "username" .: DF.validateOptional usernameValidation (DF.optionalText Nothing)
                            <*> "password" .: DF.validateOptional passwordValidation (DF.optionalText Nothing)
                            <*> "image" .: DF.optionalText Nothing
                            <*> "bio" .: DF.optionalText Nothing
                            
createArticleForm :: (Monad m) => DF.Form [Text] m CreateArticle
createArticleForm = CreateArticle <$> "title" .: DF.text Nothing
                                  <*> "description" .: DF.text Nothing
                                  <*> "body" .: DF.text Nothing
                                  <*> "tagList" .: DF.listOf (const $ DF.text Nothing) Nothing
                                  
updateArticleForm :: (Monad m) => DF.Form [Text] m UpdateArticle
updateArticleForm = UpdateArticle <$> "title" .: DF.optionalText Nothing
                                  <*> "description" .: DF.optionalText Nothing
                                  <*> "body" .: DF.optionalText Nothing