import PaddockCore

// Run as `php` or `composer` (symlinks to this binary): become that program, without parsing
// arguments or contacting the daemon. Otherwise this is the `paddock` command line.
MultiCall.runIfInvokedAsShim()
Paddock.main()
