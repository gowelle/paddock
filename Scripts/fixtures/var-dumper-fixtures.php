<?php
// Generates Tests/Fixtures/var-dumper/<version>.json: real Symfony VarDumper payloads, exactly as its dump
// server client sends them, each with the text VarDumper's own CliDumper prints for it. Paddock's decoder is
// tested against these (Tests/PaddockCoreTests/DumpDecoderTests.swift).
//
// To regenerate (in a scratch folder, with Paddock's PHP and Composer; nothing is added to this repository
// but the JSON):
//   composer require symfony/var-dumper:^8.0     # and again, elsewhere, with ^6.4
//   cp Scripts/fixtures/var-dumper-fixtures.php /private/tmp/<neutral folder>/gen.php
//   cd /private/tmp/<neutral folder> && php -n gen.php <scratch>/vendor/autoload.php > v8.json
// Run it from a neutral path: the closure case records this file's path, and a home folder must not end up
// in a fixture.
require $argv[1];

use Symfony\Component\VarDumper\Cloner\VarCloner;
use Symfony\Component\VarDumper\Dumper\CliDumper;

#[AllowDynamicProperties]
class Order {
    public int $id = 1042;
    public ?string $note = null;
    protected array $lines = ['widget' => 2, 'gadget' => 1];
    private float $total = 59.0;
    public function __construct(public ?Order $parent = null) {}
}
enum Status { case Shipped; case Pending; }
enum Suit: string { case Hearts = 'H'; case Spades = 'S'; }

function cloner(): VarCloner { return new VarCloner(); }

$shared = new stdClass(); $shared->name = 'shared';
$recursive = new stdClass(); $recursive->self = $recursive; $recursive->n = 1;
$dynamic = new Order(); $dynamic->extra = 'added later';
$referenced = 5; $withRefs = ['a' => &$referenced, 'b' => &$referenced, 'c' => 6];
$nestedRefArray = [1, 2]; $arrRef = ['x' => &$nestedRefArray, 'y' => &$nestedRefArray];
$big = range(1, 20);
$deep = ['l1' => ['l2' => ['l3' => ['l4' => 'bottom']]]];

$cases = [
    'int' => [42], 'negative int' => [-7], 'float' => [1.5], 'whole float' => [2.0], 'inf' => [INF], 'neg inf' => [-INF], 'nan' => [NAN],
    'true' => [true], 'false' => [false], 'null' => [null],
    'empty string' => [''], 'string' => ['hello'], 'unicode string' => ["h\u{e9}llo \u{2603}"],
    'multiline string' => ["first line\nsecond line\nthird"], 'string ending in newline' => ["one\n"],
    'control characters' => ["tab\there\x01ctl\x7f"], 'binary string' => ["\xff\xfe\x00bin"],
    'quotes and backslash' => ['say "hi" \\ there'],
    'long string cut' => ['abcdefghijklmnopqrstuvwxyz', fn ($c) => $c->setMaxString(10)],
    'empty array' => [[]], 'list' => [[1, 2, 3]], 'assoc' => [['a' => 1, 'b' => [true, null], 'c' => 'x']],
    'mixed keys' => [[0 => 'a', 'k' => 'b', 5 => 'c', '' => 'empty key']],
    'nested' => [$deep],
    'array cut by items' => [$big, fn ($c) => $c->setMaxItems(5)],
    'array cut by depth' => [$deep, null, fn ($d) => $d->withMaxDepth(1)],
    'items per depth' => [$big, null, fn ($d) => $d->withMaxItemsPerDepth(3)],
    'stdClass' => [(object) ['name' => 'Ada', 'age' => 36, 'tags' => ['a', 'b']]],
    'empty object' => [new stdClass()],
    'object with visibilities' => [new Order()],
    'object with dynamic property' => [$dynamic],
    'nested object' => [new Order(new Order())],
    'same object twice' => [[$shared, $shared, 'other' => $shared]],
    'recursive object' => [$recursive],
    'php references' => [$withRefs],
    'referenced arrays' => [$arrRef],
    'unit enum' => [Status::Shipped], 'backed enum' => [Suit::Spades], 'enums in array' => [[Status::Pending, Suit::Hearts]],
    'closure' => [fn (int $a, string ...$rest): bool => true],
    'datetime' => [new DateTimeImmutable('2026-11-22 10:14:10', new DateTimeZone('Africa/Dar_es_Salaam'))],
    'array object' => [new ArrayObject(['x' => 1, 'y' => 2])],
    'label' => [['k' => 'v'], null, fn ($d) => $d->withContext(['label' => 'my label'])],
    'label on scalar' => [7, null, fn ($d) => $d->withContext(['label' => 'count'])],
    'resource' => [fopen('php://memory', 'r')],
    'numeric string keys' => [['10' => 'ten', '1.5' => 'float-like', 'x y' => 'space']],
    'object in list of objects' => [[new Order(), (object) ['p' => [new stdClass()]]]],
    'int limits' => [[PHP_INT_MAX, PHP_INT_MIN, 0, -0.0, 1e100, 0.1 + 0.2]],
];

$dumper = new CliDumper();
$dumper->setColors(false);
$out = [];
foreach ($cases as $name => $case) {
    $cloner = cloner();
    if (isset($case[1])) { $case[1]($cloner); }
    $data = $cloner->cloneVar($case[0]);
    if (isset($case[2])) { $data = $case[2]($data); }
    $context = [
        'timestamp' => 1795310050.25,
        'request' => ['uri' => 'https://shop.test/orders/1042?tab=items', 'method' => 'GET',
                      'controller' => cloner()->cloneVar('App\\Http\\Controllers\\OrderController@show'), 'identifier' => 'a1b2c3d4'],
        'source' => ['name' => 'OrderController.php', 'file' => '/Users/you/Paddock/shop/app/Http/Controllers/OrderController.php',
                     'line' => 42, 'file_excerpt' => false],
    ];
    $out[] = ['name' => $name, 'payload' => base64_encode(serialize([$data, $context])), 'text' => $dumper->dump($data, true)];
}
// One as the command line sends it.
$data = cloner()->cloneVar(['queued' => 3]);
$out[] = ['name' => 'from the command line', 'payload' => base64_encode(serialize([$data, [
    'timestamp' => 1795310051.5,
    'cli' => ['command_line' => 'artisan queue:work --tries=3', 'identifier' => 'e5f6'],
    'source' => ['name' => 'Worker.php', 'file' => '/Users/you/Paddock/shop/app/Jobs/Worker.php', 'line' => 9, 'file_excerpt' => false,
                 'project_dir' => '/Users/you/Paddock/shop', 'file_relative' => 'app/Jobs/Worker.php'],
]])), 'text' => $dumper->dump($data, true)];
echo json_encode($out, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE), "\n";
