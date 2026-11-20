<?php

$paddockDriversDir = __DIR__.'/../Valet/Drivers';

require_once $paddockDriversDir.'/ValetDriver.php';

foreach (scandir($paddockDriversDir) as $file) {
    $path = $paddockDriversDir.'/'.$file;
    if (substr($file, 0, 1) !== '.' && ! is_dir($path)) {
        require_once $path;
    }
}

// Unset our loop variables to keep them from leaking into the user's app.
unset($file, $path, $paddockDriversDir);
