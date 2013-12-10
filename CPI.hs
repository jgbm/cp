import Control.Monad.Error
import Data.Char (isSpace)
import Data.List (partition)
import CP.Check
import CP.Expand
import CP.Norm
import CP.Syntax
import CP.Printer
import CP.Parser
import System.Console.Haskeline
import System.Environment (getArgs)


traceBehavior i b =
    case b of
      [] -> si ++ "{}"
      (t:ts) -> unlines ((si ++ st t) : [sp ++ st t | t <- ts])
    where si = '(' : show i ++ ") "
          sp = replicate (length si) ' '
          st (v, t) =  v ++ ": " ++ show (pretty t)

into (t, Left err) = Left (unlines ([traceBehavior i b | (i, b) <- zip [1..] t] ++ [err]))
into (t, Right v)  = Right t

interp ds (Left d) = return (addDefn ds d)
interp ds (Right (Assert p b isCheck)) =
    case do p' <- expandP ds p
            b' <- expandB ds b
            t <- into (runCheck (check p') b')
            return (t, b', normalize p' b') of
      Left err ->
          do if isCheck then putStrLn ("Check failed: " ++ show (pretty (Assert p b isCheck))) else return ()
             putStrLn err
             return ds
      Right (t, b', (executed, simplified))
          | isCheck -> return ds
          | otherwise ->
              do sequence_ [putStrLn (traceBehavior i b) | (i, b) <- zip [1..] t]
                 putStrLn (unlines ["Execution results in:",
                                    displayS (renderPretty 0.8 120 (pretty executed)) "",
                                    "which can be further simplified to:",
                                    displayS (renderPretty 0.8 120 (pretty simplified)) ""])
                 return ds

repl ds = do s <- getInputLine "> "
             case trim `fmap` s of
               Nothing   -> return ()
               Just ":q" -> return ()
               Just ""   -> repl ds
               Just ('-' : '-' : _) -> repl ds
               Just s'   -> case parse tops s' of
                              Left err -> do outputStrLn err
                                             repl ds
                              Right ts -> liftIO (foldM interp ds ts) >>= repl
    where trim = f . f
              where f = reverse . dropWhile isSpace

parseFile ds fn =
    do s <- readFile fn
       case parse tops s of
         Left err -> do putStrLn err
                        return ds
         Right ts -> foldM interp ds ts

main = do args <- getArgs
          let (interactive, files) = partition ("-i" ==) args
          ds <- foldM parseFile emptyDefns files
          if not (null interactive) || null files then runInputT defaultSettings (repl ds) else return ()
