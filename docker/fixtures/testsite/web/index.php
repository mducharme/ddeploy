<?php
// Fixture app for the docker test harness. Reads the .env that db_ensure
// (lib/db.sh, db_env_scheme=laravel) wrote at the repo root, one level
// above this docroot, and proves the credentials actually work by
// running a real query — not just that the file exists.
echo "MARKER=v1\n";
echo "MAX_EXEC=" . ini_get('max_execution_time') . "\n";

$envFile = dirname(__DIR__) . '/.env';
$vars = [];
if (is_readable($envFile)) {
    foreach (file($envFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        if (strpos($line, '=') === false) {
            continue;
        }
        [$k, $v] = explode('=', $line, 2);
        $vars[trim($k)] = trim($v);
    }
}

$host = $vars['DB_HOST'] ?? '';
$db   = $vars['DB_DATABASE'] ?? '';
$user = $vars['DB_USERNAME'] ?? '';
$pass = $vars['DB_PASSWORD'] ?? '';

if ($host === '') {
    echo "DB_SKIPPED (no .env)\n";
    exit;
}

try {
    $pdo = new PDO("mysql:host=$host;dbname=$db", $user, $pass, [PDO::ATTR_TIMEOUT => 3]);
    $pdo->query('SELECT 1');
    echo "DB_OK\n";
} catch (Throwable $e) {
    echo 'DB_FAIL: ' . $e->getMessage() . "\n";
}
