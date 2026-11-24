import Foundation

/// One request to the small PHP/PDO program that reads a database service. Everything travels in the
/// environment, so no value reaches a shell or a command line.
struct DatabaseRequest: Encodable, Sendable {
    let action: String
    let driver: String
    let host: String
    let port: Int
    let user: String
    let password: String
    let database: String
    var schema: String?
    var table: String?
    var sql: String?
    var limit: Int?
    var search: String?
    var key: [String: String?]? = nil
    var changes: [String: String?]? = nil
    var expected: [String: String?]? = nil
    var values: [String: String?]? = nil
}

/// Runs the bundled PHP with a fixed PDO program and returns what it answered.
struct PHPDatabaseBridge: Sendable {
    let php: URL
    let runner: CommandRunner

    init(php: URL, runner: CommandRunner = SystemCommandRunner()) {
        self.php = php
        self.runner = runner
    }

    func run<Answer: Decodable>(_ request: DatabaseRequest, as: Answer.Type,
                                inFile: Bool = false) throws -> Answer {
        let data: Data
        do {
            data = try JSONEncoder().encode(request)
        } catch {
            throw DatabaseError.failed("Paddock couldn't prepare the database request.")
        }
        var environment = ProcessInfo.processInfo.environment
        var requestFile: URL?
        if inFile {
            // A write can hold a long value; the environment has a size limit on macOS. 0600 at creation.
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("paddock-db-\(UUID().uuidString).json")
            guard FileManager.default.createFile(atPath: url.path, contents: Data(data.base64EncodedString().utf8),
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw DatabaseError.failed("Paddock couldn't prepare the write request.")
            }
            requestFile = url
            environment[Self.fileKey] = url.path
        } else {
            environment[Self.requestKey] = data.base64EncodedString()
        }
        // The function's scope, not the `if`'s: a defer inside that block runs as the block exits, deleting
        // the file before PHP is started.
        defer { if let requestFile { try? FileManager.default.removeItem(at: requestFile) } }

        let result: (status: Int32, output: String)
        do {
            result = try runner.run(php.path, Self.arguments, environment: environment, timeout: 30)
        } catch {
            throw DatabaseError.failed("Paddock couldn't start PHP to read the database: \(error.localizedDescription)")
        }
        guard let replyData = result.output.data(using: .utf8), !replyData.isEmpty else {
            throw DatabaseError.failed("PHP gave no answer while reading the database (exit \(result.status)).")
        }
        let reply: Reply<Answer>
        do {
            reply = try JSONDecoder().decode(Reply<Answer>.self, from: replyData)
        } catch {
            throw DatabaseError.failed("Paddock couldn't read PHP's answer about the database.")
        }
        if !reply.ok {
            throw DatabaseError.failed(reply.error ?? "The database refused the request.")
        }
        guard let answer = reply.result else {
            throw DatabaseError.failed("PHP gave no result while reading the database.")
        }
        return answer
    }

    private struct Reply<Answer: Decodable>: Decodable {
        let ok: Bool
        let error: String?
        let result: Answer?
    }

    static let requestKey = "PADDOCK_DB_REQUEST"
    static let fileKey = "PADDOCK_DB_REQUEST_FILE"

    private static let arguments = [
        "-d", "display_errors=0", "-d", "log_errors=0", "-d", "error_reporting=0", "-r", script,
    ]

    /// A fixed program, never built from user input. It reads one request from its environment and writes
    /// one JSON answer. The read-only action opens a read-only transaction, so a write cannot slip through
    /// even when the first keyword looks harmless.
    static let script = #"""
    $raw = getenv('PADDOCK_DB_REQUEST');
    $file = getenv('PADDOCK_DB_REQUEST_FILE');
    if (!is_string($raw) && is_string($file) && $file !== '') {
        $raw = @file_get_contents($file);
        @unlink($file);
        if (!is_string($raw)) fail('Paddock could not read its write request.');
    }
    $request = is_string($raw) ? json_decode(base64_decode($raw), true) : null;
    function reply($payload) {
        echo json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE);
        exit(0);
    }
    function fail($message) { reply(['ok' => false, 'error' => (string)$message]); }
    function ident($driver, $name) {
        $quote = $driver === 'mysql' ? '`' : '"';
        return $quote . str_replace($quote, $quote . $quote, $name) . $quote;
    }
    function text($value) {
        if ($value === null) return null;
        if (is_bool($value)) return $value ? 'true' : 'false';
        if (!is_scalar($value)) {
            return json_encode($value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE);
        }
        return (string)$value;
    }
    function cell($value) {
        $text = text($value);
        if ($text !== null && strlen($text) > 4096) $text = substr($text, 0, 4096) . '…';
        return $text;
    }
    function binaryTypes() {
        return ['binary', 'varbinary', 'tinyblob', 'blob', 'mediumblob', 'longblob', 'geometry', 'point',
                'linestring', 'polygon', 'multipoint', 'multilinestring', 'multipolygon', 'geometrycollection'];
    }
    // The binary columns of a table: left out of a row read, never compared or written.
    function binaryColumns($pdo, $driver, $schema, $table) {
        if ($driver === 'mysql') {
            $types = binaryTypes();
            $marks = implode(', ', array_fill(0, count($types), '?'));
            $statement = $pdo->prepare('SELECT column_name FROM information_schema.columns WHERE table_schema = ?'
                . ' AND table_name = ? AND data_type IN (' . $marks . ')');
            $statement->execute(array_merge([$schema, $table], $types));
        } else {
            $statement = $pdo->prepare("SELECT column_name FROM information_schema.columns WHERE table_schema = ?"
                . " AND table_name = ? AND data_type = 'bytea'");
            $statement->execute([$schema, $table]);
        }
        $set = [];
        foreach ($statement->fetchAll(PDO::FETCH_COLUMN) as $name) $set[(string)$name] = true;
        return $set;
    }
    function qualified($driver, $schema, $table) {
        return ($schema ? ident($driver, (string)$schema) . '.' : '') . ident($driver, $table);
    }
    // The row lock's condition: the key's columns, NULL-safe even though a key is never NULL.
    function keyCondition($driver, $key) {
        $conditions = [];
        $parameters = [];
        foreach ($key as $column => $value) {
            $conditions[] = ident($driver, (string)$column) . ($driver === 'mysql' ? ' <=> ?' : ' IS NOT DISTINCT FROM ?');
            $parameters[] = $value;
        }
        return [implode(' AND ', $conditions), $parameters];
    }
    function writeKey($request) {
        return isset($request['key']) && is_array($request['key']) ? $request['key'] : [];
    }
    // The row as the database holds it now, locked until the transaction ends.
    function lockedRow($pdo, $driver, $name, $key) {
        [$where, $parameters] = keyCondition($driver, $key);
        $statement = $pdo->prepare('SELECT * FROM ' . $name . ' WHERE ' . $where . ' FOR UPDATE');
        $statement->execute($parameters);
        $row = $statement->fetch(PDO::FETCH_ASSOC);
        return is_array($row) ? $row : null;
    }
    // Whether the locked row differs from the row the editor opened, past the 4096-character clip.
    function differs($row, $expected) {
        foreach ($expected as $column => $value) {
            if (!array_key_exists($column, $row)) return true;
            $actual = text($row[$column]);
            if ($value === null ? $actual !== null : (string)$value !== $actual) return true;
        }
        return false;
    }
    function beginWrite($pdo, $driver) {
        if ($driver === 'mysql') $pdo->exec('SET SESSION innodb_lock_wait_timeout = 5');
        $pdo->beginTransaction();
        if ($driver === 'pgsql') $pdo->exec("SET LOCAL statement_timeout = '5s'");
    }
    // A LIKE pattern matching the text anywhere, with LIKE's own marks (% _ and the escape) taken literally.
    function likePattern($text) {
        return '%' . str_replace(['\\', '%', '_'], ['\\\\', '\\%', '\\_'], $text) . '%';
    }
    // The names of a table's columns, in order; binary columns are left out of MySQL's text search.
    function columnNames($pdo, $driver, $schema, $table) {
        if ($driver === 'mysql') {
            $types = binaryTypes();
            $marks = implode(', ', array_fill(0, count($types), '?'));
            $statement = $pdo->prepare('SELECT column_name AS name FROM information_schema.columns WHERE table_schema = ? AND table_name = ? AND data_type NOT IN (' . $marks . ') ORDER BY ordinal_position');
            $statement->execute(array_merge([$schema, $table], $types));
        } else {
            $statement = $pdo->prepare('SELECT column_name AS name FROM information_schema.columns WHERE table_schema = ? AND table_name = ? ORDER BY ordinal_position');
            $statement->execute([$schema, $table]);
        }
        return array_map('strval', $statement->fetchAll(PDO::FETCH_COLUMN));
    }
    function readRows($statement, $limit) {
        $columns = [];
        $count = $statement->columnCount();
        for ($i = 0; $i < $count; $i++) {
            $meta = @$statement->getColumnMeta($i);
            $columns[] = is_array($meta) && isset($meta['name']) ? $meta['name'] : 'column_' . ($i + 1);
        }
        $rows = [];
        while ($row = $statement->fetch(PDO::FETCH_NUM)) {
            if (count($rows) >= $limit) {
                return ['columns' => $columns, 'rows' => $rows, 'truncated' => true];
            }
            $rows[] = array_map('cell', $row);
        }
        return ['columns' => $columns, 'rows' => $rows, 'truncated' => false];
    }
    try {
        if (!is_array($request)) fail('Paddock sent an unreadable database request.');
        foreach (['action', 'driver', 'host', 'port', 'user', 'password', 'database'] as $key) {
            if (!array_key_exists($key, $request)) fail('The database request is missing ' . $key . '.');
        }
        $driver = (string)$request['driver'];
        if ($driver !== 'pgsql' && $driver !== 'mysql') fail('Paddock can only read PostgreSQL and MySQL.');
        $limit = isset($request['limit']) ? (int)$request['limit'] : 50;
        if ($limit < 1) $limit = 1;
        if ($limit > 1000) $limit = 1000;
        $host = (string)$request['host'];
        $port = (int)$request['port'];
        $user = (string)$request['user'];
        $password = (string)$request['password'];
        $database = (string)$request['database'];
        $dsn = $driver === 'mysql'
            ? "mysql:host=$host;port=$port;dbname=$database;charset=utf8mb4"
            : "pgsql:host=$host;port=$port;dbname=$database";
        $options = [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_TIMEOUT => 5];
        if ($driver === 'mysql') {
            $options[PDO::ATTR_EMULATE_PREPARES] = false;
            $options[PDO::MYSQL_ATTR_FOUND_ROWS] = true; // an unchanged save still counts the row as matched
        }
        $pdo = new PDO($dsn, $user, $password, $options);
        $action = (string)$request['action'];
        switch ($action) {
        case 'databases':
            if ($driver === 'mysql') {
                $statement = $pdo->query("SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys') ORDER BY schema_name");
            } else {
                $statement = $pdo->query('SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname');
            }
            reply(['ok' => true, 'result' => $statement->fetchAll(PDO::FETCH_COLUMN)]);
        case 'tables':
            $tables = [];
            if ($driver === 'mysql') {
                // Aliases: MySQL may name information_schema's own columns in upper case.
                $statement = $pdo->prepare('SELECT table_name AS name, table_type AS kind FROM information_schema.tables WHERE table_schema = ? ORDER BY table_name');
                $statement->execute([$database]);
                foreach ($statement as $row) {
                    $tables[] = [
                        'schema' => null,
                        'name' => (string)$row['name'],
                        'kind' => stripos((string)$row['kind'], 'VIEW') !== false ? 'view' : 'table',
                    ];
                }
            } else {
                $statement = $pdo->query("SELECT table_schema, table_name, table_type FROM information_schema.tables WHERE table_catalog = current_database() AND table_schema NOT IN ('pg_catalog', 'information_schema') ORDER BY table_schema, table_name");
                foreach ($statement as $row) {
                    $tables[] = [
                        'schema' => (string)$row['table_schema'],
                        'name' => (string)$row['table_name'],
                        'kind' => stripos((string)$row['table_type'], 'VIEW') !== false ? 'view' : 'table',
                    ];
                }
            }
            reply(['ok' => true, 'result' => $tables]);
        case 'columns':
            $table = isset($request['table']) ? (string)$request['table'] : '';
            if ($table === '') fail('No table was named.');
            $schema = isset($request['schema']) ? (string)$request['schema'] : ($driver === 'mysql' ? $database : 'public');
            if ($driver === 'mysql') {
                $statement = $pdo->prepare('SELECT column_name AS name, column_type AS type, is_nullable AS nullable, column_default AS default_value, extra AS extra, data_type AS data_type FROM information_schema.columns WHERE table_schema = ? AND table_name = ? ORDER BY ordinal_position');
            } else {
                $statement = $pdo->prepare('SELECT column_name AS name, data_type AS type, is_nullable AS nullable, column_default AS default_value, is_generated AS generated, is_identity AS identity FROM information_schema.columns WHERE table_schema = ? AND table_name = ? ORDER BY ordinal_position');
            }
            $statement->execute([$schema, $table]);
            $primary = $pdo->prepare("SELECT kcu.column_name FROM information_schema.table_constraints tc JOIN information_schema.key_column_usage kcu ON tc.constraint_schema = kcu.constraint_schema AND tc.constraint_name = kcu.constraint_name AND tc.table_name = kcu.table_name WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_schema = ? AND tc.table_name = ?");
            $primary->execute([$schema, $table]);
            $keys = [];
            foreach ($primary->fetchAll(PDO::FETCH_COLUMN) as $name) $keys[(string)$name] = true;
            $columns = [];
            foreach ($statement as $row) {
                $binary = false;
                $generated = false;
                $identity = false;
                $default = $row['default_value'] === null ? null : (string)$row['default_value'];
                if ($driver === 'mysql') {
                    $binary = in_array(strtolower((string)$row['data_type']), binaryTypes(), true);
                    $generated = stripos((string)$row['extra'], 'VIRTUAL GENERATED') !== false
                        || stripos((string)$row['extra'], 'STORED GENERATED') !== false;
                    $identity = stripos((string)$row['extra'], 'auto_increment') !== false;
                } else {
                    $binary = strtolower((string)$row['type']) === 'bytea';
                    $generated = strtoupper((string)$row['generated']) !== 'NEVER';
                    $identity = strtoupper((string)$row['identity']) === 'YES'
                        || ($default !== null && stripos($default, 'nextval(') === 0);
                }
                $columns[] = [
                    'name' => (string)$row['name'],
                    'type' => (string)$row['type'],
                    'nullable' => strtoupper((string)$row['nullable']) === 'YES',
                    'default' => $default,
                    'primary' => isset($keys[(string)$row['name']]),
                    'binary' => $binary,
                    'generated' => $generated,
                    'identity' => $identity,
                ];
            }
            reply(['ok' => true, 'result' => $columns]);
        case 'rows':
            $table = isset($request['table']) ? (string)$request['table'] : '';
            if ($table === '') fail('No table was named.');
            $schema = isset($request['schema']) ? $request['schema'] : null;
            $name = ($schema ? ident($driver, (string)$schema) . '.' : '') . ident($driver, $table);
            $search = isset($request['search']) ? trim((string)$request['search']) : '';
            if ($search === '') {
                $statement = $pdo->query("SELECT * FROM $name LIMIT $limit");
                reply(['ok' => true, 'result' => readRows($statement, $limit)]);
            }
            // The whole table is searched in the database, not just the rows already shown: every column's
            // text is matched, with ILIKE's case folding on PostgreSQL and LOWER on MySQL.
            $columns = columnNames($pdo, $driver, $driver === 'mysql' ? $database : ($schema ? (string)$schema : 'public'), $table);
            if (empty($columns)) fail('This table has no column to search.');
            $pattern = likePattern($search);
            if ($driver === 'pgsql') {
                $tests = [];
                foreach ($columns as $column) $tests[] = ident($driver, $column) . '::text ILIKE ?';
                $parameters = array_fill(0, count($tests), $pattern);
                $pdo->exec('BEGIN TRANSACTION READ ONLY');
                $pdo->exec("SET LOCAL statement_timeout = '5s'");
            } else {
                $casts = [];
                foreach ($columns as $column) $casts[] = 'CAST(' . ident($driver, $column) . ' AS CHAR)';
                $tests = ['LOWER(CONCAT_WS(\' \', ' . implode(', ', $casts) . ')) LIKE LOWER(?)'];
                $parameters = [$pattern];
                $pdo->exec('SET SESSION MAX_EXECUTION_TIME = 5000');
                $pdo->exec('START TRANSACTION READ ONLY');
            }
            $statement = $pdo->prepare('SELECT * FROM ' . $name . ' WHERE ' . implode(' OR ', $tests) . ' LIMIT ' . $limit);
            $statement->execute($parameters);
            $rows = readRows($statement, $limit);
            try { $pdo->rollBack(); } catch (Throwable $ignored) {}
            reply(['ok' => true, 'result' => $rows]);
        case 'query':
            $sql = isset($request['sql']) ? trim((string)$request['sql']) : '';
            if ($sql === '') fail('No query was given.');
            $sql = rtrim($sql, "; \t\n\r");
            if (strpos($sql, ';') !== false) fail('Only one statement can be run at a time.');
            $withoutComments = preg_replace('/^(?:\s|--[^\n]*(?:\n|$)|\/\*.*?\*\/)*/s', '', $sql);
            if (!preg_match('/^(SELECT|WITH|SHOW|DESCRIBE|EXPLAIN|TABLE|VALUES)\b/i', (string)$withoutComments)) {
                fail('Only read-only queries can be run here.');
            }
            if ($driver === 'pgsql') {
                $pdo->exec('BEGIN TRANSACTION READ ONLY');
                $pdo->exec("SET LOCAL statement_timeout = '5s'");
            } else {
                $pdo->exec('SET SESSION MAX_EXECUTION_TIME = 5000');
                $pdo->exec('START TRANSACTION READ ONLY');
            }
            $statement = $pdo->query($sql);
            $rows = readRows($statement, $limit);
            try { $pdo->rollBack(); } catch (Throwable $ignored) {}
            reply(['ok' => true, 'result' => $rows]);
        case 'row':
            $table = isset($request['table']) ? (string)$request['table'] : '';
            if ($table === '') fail('No table was named.');
            $key = writeKey($request);
            if (empty($key)) fail('No row was named.');
            $schema = isset($request['schema']) && $request['schema'] !== null
                ? (string)$request['schema'] : ($driver === 'mysql' ? null : 'public');
            $name = qualified($driver, $schema, $table);
            $binary = binaryColumns($pdo, $driver, $schema ?: $database, $table);
            [$where, $parameters] = keyCondition($driver, $key);
            if ($driver === 'pgsql') {
                $pdo->exec('BEGIN TRANSACTION READ ONLY');
                $pdo->exec("SET LOCAL statement_timeout = '5s'");
            } else {
                $pdo->exec('SET SESSION MAX_EXECUTION_TIME = 5000');
                $pdo->exec('START TRANSACTION READ ONLY');
            }
            $statement = $pdo->prepare('SELECT * FROM ' . $name . ' WHERE ' . $where . ' LIMIT 1');
            $statement->execute($parameters);
            $found = $statement->fetch(PDO::FETCH_ASSOC);
            if (!is_array($found)) fail('That row is no longer there. It may have been deleted.');
            $out = [];
            foreach ($found as $column => $value) {
                if (!isset($binary[(string)$column])) $out[$column] = text($value);
            }
            try { $pdo->rollBack(); } catch (Throwable $ignored) {}
            reply(['ok' => true, 'result' => $out]);
        case 'insert':
            $table = isset($request['table']) ? (string)$request['table'] : '';
            if ($table === '') fail('No table was named.');
            $values = isset($request['values']) && is_array($request['values']) ? $request['values'] : [];
            $schema = isset($request['schema']) && $request['schema'] !== null
                ? (string)$request['schema'] : ($driver === 'mysql' ? null : 'public');
            $name = qualified($driver, $schema, $table);
            beginWrite($pdo, $driver);
            if (empty($values)) {
                if ($driver === 'pgsql') {
                    $pdo->exec('INSERT INTO ' . $name . ' DEFAULT VALUES');
                } else {
                    $pdo->exec('INSERT INTO ' . $name . ' () VALUES ()');
                }
            } else {
                $names = [];
                $marks = [];
                $parameters = [];
                foreach ($values as $column => $value) {
                    $names[] = ident($driver, (string)$column);
                    $marks[] = '?';
                    $parameters[] = $value;
                }
                $statement = $pdo->prepare('INSERT INTO ' . $name . ' (' . implode(', ', $names) . ') VALUES ('
                    . implode(', ', $marks) . ')');
                $statement->execute($parameters);
            }
            $pdo->commit();
            reply(['ok' => true, 'result' => ['affected' => 1]]);
        case 'update':
            $table = isset($request['table']) ? (string)$request['table'] : '';
            if ($table === '') fail('No table was named.');
            $key = writeKey($request);
            if (empty($key)) fail('No row was named.');
            $changes = isset($request['changes']) && is_array($request['changes']) ? $request['changes'] : [];
            if (empty($changes)) fail('Nothing was changed.');
            $expected = isset($request['expected']) && is_array($request['expected']) ? $request['expected'] : [];
            $schema = isset($request['schema']) && $request['schema'] !== null
                ? (string)$request['schema'] : ($driver === 'mysql' ? null : 'public');
            $name = qualified($driver, $schema, $table);
            beginWrite($pdo, $driver);
            $found = lockedRow($pdo, $driver, $name, $key);
            if ($found === null) fail('That row is no longer there. It may have been deleted.');
            if (differs($found, $expected)) {
                fail('This row changed since it was read. Reload and try again.');
            }
            $sets = [];
            $parameters = [];
            foreach ($changes as $column => $value) {
                $sets[] = ident($driver, (string)$column) . ' = ?';
                $parameters[] = $value;
            }
            [$where, $keyParameters] = keyCondition($driver, $key);
            $statement = $pdo->prepare('UPDATE ' . $name . ' SET ' . implode(', ', $sets) . ' WHERE ' . $where);
            $statement->execute(array_merge($parameters, $keyParameters));
            if ($statement->rowCount() < 1) {
                fail('This row changed since it was read. Reload and try again.');
            }
            $pdo->commit();
            reply(['ok' => true, 'result' => ['affected' => 1]]);
        case 'delete':
            $table = isset($request['table']) ? (string)$request['table'] : '';
            if ($table === '') fail('No table was named.');
            $key = writeKey($request);
            if (empty($key)) fail('No row was named.');
            $expected = isset($request['expected']) && is_array($request['expected']) ? $request['expected'] : [];
            $schema = isset($request['schema']) && $request['schema'] !== null
                ? (string)$request['schema'] : ($driver === 'mysql' ? null : 'public');
            $name = qualified($driver, $schema, $table);
            beginWrite($pdo, $driver);
            $found = lockedRow($pdo, $driver, $name, $key);
            if ($found === null) fail('That row is no longer there. It may have been deleted.');
            if (differs($found, $expected)) {
                fail('This row changed since it was read. Reload and try again.');
            }
            [$where, $keyParameters] = keyCondition($driver, $key);
            $statement = $pdo->prepare('DELETE FROM ' . $name . ' WHERE ' . $where);
            $statement->execute($keyParameters);
            if ($statement->rowCount() < 1) {
                fail('This row changed since it was read. Reload and try again.');
            }
            $pdo->commit();
            reply(['ok' => true, 'result' => ['affected' => 1]]);
        default:
            fail('Paddock does not know that database request.');
        }
    } catch (Throwable $error) {
        try { if (isset($pdo) && $pdo->inTransaction()) $pdo->rollBack(); } catch (Throwable $ignored) {}
        fail($error->getMessage());
    }
    """#
}

