# Vendored Laravel Valet router

Source: https://github.com/laravel/valet, tag `v4.14.0` (MIT, see `LICENSE.md`).

Copied unmodified except for the edits listed below:

- `server.php`
- `cli/Valet/Server.php`
- `cli/Valet/Drivers/` (all drivers, including `Specific/`)
- `cli/includes/require-drivers.php`
- `cli/templates/404.html` (required by `Server.php`)

## Edits

1. `server.php`: `VALET_HOME_PATH` is no longer derived from the file owner's
   `~/.config/valet`. It is taken from the `PADDOCK_ROUTER_HOME` FastCGI param
   (`$_SERVER`, falling back to `getenv`). If it is missing the script answers
   HTTP 500 and exits.
2. `server.php`: the two `require_once './cli/...'` calls are now relative to
   `__DIR__`, so they no longer depend on the working directory.
3. `cli/includes/require-drivers.php`: the driver directory is now
   `__DIR__.'/../Valet/Drivers'` instead of `./cli/Valet/Drivers`; the helper
   variable is unset at the end with the others.
4. `cli/templates/404.html`: the page title reads `Paddock - Not Found`
   instead of `Valet - Not Found`, so visitors see Paddock's name.

No Homebrew paths: the v4.14.0 files copied here contain no references to
Homebrew, `/usr/local` or `/opt` (verified with grep), so nothing needed
removing for that requirement.
