-- Runs once, when the data directory is created. The 'dev' user (password from .env) may
-- create and use any database whose name starts with dev_ (one per project), nothing else.
GRANT ALL PRIVILEGES ON `dev\_%`.* TO 'dev'@'%';
