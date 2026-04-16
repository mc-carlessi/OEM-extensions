#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(decode_json);
use Time::Local qw(timegm);

# --- Credential Handling ---
# OEM passes credentials via STDIN. We initialize variables to store them.
my $cluster_user = '';
my $cluster_pass = '';
my $rest_user    = '';
my $rest_pass    = '';

while (my $line = <STDIN>) {
    chomp $line;
    # MySQL Cluster DB credentials
    if ($line =~ /^MYSQL_USERNAME=(.*)$/) { $cluster_user = $1; next; }
    if ($line =~ /^MYSQL_PASSWORD=(.*)$/) { $cluster_pass = $1; next; }
    # Router REST API credentials (named as per OEM Named Credentials)
    if ($line =~ /(?:Cred_\d+:)?OracleMySQLUsername=(.*)$/) { $rest_user = $1; next; }
    if ($line =~ /(?:Cred_\d+:)?OracleMySQLPassword=(.*)$/) { $rest_pass = $1; next; }
}

die "EM_ERROR: Missing cluster credentials\n" if $cluster_user eq '' || $cluster_pass eq '';
die "EM_ERROR: Missing router REST credentials\n" if $rest_user eq '' || $rest_pass eq '';

# --- Target Context ---
# Target properties are usually passed via Environment Variables by the OEM Agent
my $mysql_host = $ENV{MYSQL_HOST} // '';
my $mysql_port = $ENV{MYSQL_PORT} // 3306;
die "EM_ERROR: MYSQL_HOST not defined\n" if $mysql_host eq '';

sub format_uptime {
    my ($time_started) = @_;
    return '0s' if !$time_started;

    # Parse ISO 8601 timestamp
    if ($time_started =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/) {
        my ($y,$m,$d,$H,$M,$S) = ($1,$2,$3,$4,$5,$6);
        my $start = timegm($S, $M, $H, $d, $m - 1, $y - 1900);
        my $now   = time();
        my $diff  = $now - $start;
        $diff = 0 if $diff < 0;

        my $days  = int($diff / 86400); $diff %= 86400;
        my $hours = int($diff / 3600);  $diff %= 3600;
        my $mins  = int($diff / 60);
        my $secs  = $diff % 60;

        return sprintf('%dd %02dh %02dm %02ds', $days, $hours, $mins, $secs);
    }
    return '0s';
}

# --- Metadata Retrieval ---
# Querying the InnoDB Cluster metadata to discover registered routers
my $sql = q{
SELECT
  router_id,
  address,
  attributes->>"$.Configuration.http_server.port" AS port
FROM mysql_innodb_cluster_metadata.routers
ORDER BY router_id
};

# Securely passing password to the mysql client via environment variable
local $ENV{MYSQL_PWD} = $cluster_pass;

# Execute mysql client in batch mode (-B) without headers (-N)
open(my $mysql_fh, '-|',
    'mysql', '-h', $mysql_host, '-P', $mysql_port, '-u', $cluster_user, '-N', '-B', '-e', $sql
) or die "EM_ERROR: Failed to execute mysql client\n";

while (my $row = <$mysql_fh>) {
    chomp $row;
    next if $row =~ /^\s*$/;

    my ($router_id, $address, $port) = split(/\t/, $row, 3);
    $port ||= 8443; # Fallback to default Router REST port if not found

    # --- Router REST API Call ---
    my $url = "https://$address:$port/api/20190715/router/status";

    # Executing curl via system list to prevent shell injection
    my $response = qx{/usr/bin/curl -k -s --connect-timeout 5 -u "$rest_user:$rest_pass" "$url" 2>/dev/null};

    my $status  = 0;
    my $version = 'unknown';
    my $uptime  = '0s';

    if ($response) {
        # Parsing JSON response and handling potential decoding errors
        my $data = eval { decode_json($response) };
        if ($data && ref($data) eq 'HASH') {
            $version = $data->{version} // 'unknown';
            $uptime  = format_uptime($data->{timeStarted});
            # If we got a valid version, consider the router UP
            $status  = ($version ne 'unknown') ? 1 : 0;
        }
    }

    # Output formatted for OEM Metric Extension (Multi-column result)
    print join('|', $router_id, $address, $port, $status, $version, $uptime), "\n";
}

close($mysql_fh);
exit 0;