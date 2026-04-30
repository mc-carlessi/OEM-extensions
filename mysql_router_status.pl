#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(decode_json);
use Time::Local qw(timegm);

# --- 1. Credential Handling (Standard OEM Pattern) ---
# OEM passes sensitive credentials via STDIN to keep them out of the process list.
my $cluster_user = '';
my $cluster_pass = '';
my $rest_user    = '';
my $rest_pass    = '';

while (my $line = <STDIN>) {
    chomp $line;
    # Database credentials for metadata access
    if ($line =~ /^MYSQL_USERNAME=(.*)$/) { $cluster_user = $1; next; }
    if ($line =~ /^MYSQL_PASSWORD=(.*)$/) { $cluster_pass = $1; next; }
    
    # Router REST API credentials (using OEM Named Credentials mapping)
    if ($line =~ /(?:Cred_\d+:)?OracleMySQLUsername=(.*)$/) { $rest_user = $1; next; }
    if ($line =~ /(?:Cred_\d+:)?OracleMySQLPassword=(.*)$/) { $rest_pass = $1; next; }
}

# Validation: Ensure we have all necessary credentials before proceeding
die "EM_ERROR: Missing cluster credentials\n" if $cluster_user eq '' || $cluster_pass eq '';
die "EM_ERROR: Missing router REST credentials\n" if $rest_user eq '' || $rest_pass eq '';

# --- 2. Environment Setup & HA Handling ---
# In High Availability (HA) environments, OEM may provide multiple hosts/ports as comma-separated strings.
my $raw_hosts = $ENV{MYSQL_HOST} // '';
my $raw_ports = $ENV{MYSQL_PORT} // '3306';

die "EM_ERROR: MYSQL_HOST not defined\n" if $raw_hosts eq '';

# Split strings into arrays and trim whitespace for robust connection attempts
my @hosts = map { s/^\s+|\s+$//gr } split(',', $raw_hosts);
my @ports = map { s/^\s+|\s+$//gr } split(',', $raw_ports);

# Utility function: Converts ISO 8601 uptime (e.g., 2024-01-01T10:00:00Z) into a human-readable format.
sub format_uptime {
    my ($time_started) = @_;
    return '0s' if !$time_started;
    
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

# --- 3. Database Discovery (Failover Loop) ---
# We need to query the InnoDB Cluster metadata to find all registered routers.
# This loop tries every host provided by OEM until one responds.
my $sql = q{
SELECT
  router_id,
  address,
  attributes->>"$.Configuration.http_server.port" AS port
FROM mysql_innodb_cluster_metadata.routers
ORDER BY router_id
};

local $ENV{MYSQL_PWD} = $cluster_pass;
my $metadata_retrieved = 0;
my @router_list;

foreach my $index (0 .. $#hosts) {
    my $current_host = $hosts[$index];
    my $current_port = $ports[$index] // $ports[0] // 3306;

    # Using the LIST form of open() to prevent shell injection and handle the '$' character in SQL correctly.
    my @cmd = ('mysql', '-h', $current_host, '-P', $current_port, '-u', $cluster_user, 
               '-N', '-B', '--connect-timeout=5', '-e', $sql);
    
    if (open(my $mysql_fh, "-|", @cmd)) {
        my @rows = <$mysql_fh>;
        close($mysql_fh);
        
        # If the command succeeded ($? == 0) and returned data, we stop the failover loop
        if ($? == 0 && @rows) {
            @router_list = @rows;
            $metadata_retrieved = 1;
            last; 
        }
    }
}

# If no host responded, we signal a failure to OEM
if (!$metadata_retrieved) {
    die "EM_ERROR: Could not connect to any of the provided MySQL hosts: $raw_hosts\n";
}

# --- 4. Metric Collection (REST API) ---
# For each router found in the database, we query its own REST API for status/metrics.
foreach my $row (@router_list) {
    chomp $row;
    next if $row =~ /^\s*$/;

    my ($router_id, $address, $port) = split(/\t/, $row, 3);
    $port ||= 8443; # Default Router REST port if metadata is missing it

    # Endpoint for basic status. To monitor connections, change the API endpoint (e.g., /api/20190715/routes)
    my $url = "https://$address:$port/api/20190715/router/status";
    
    # Use curl to fetch JSON data. 
    # Use '--connect-timeout' to prevent the script from hanging on a single down router.
    my $response = qx{/usr/bin/curl -k -s --connect-timeout 5 -u "$rest_user:$rest_pass" '$url' 2>/dev/null};

    my $status  = 0;
    my $version = 'unknown';
    my $uptime  = '0s';

    if ($response) {
        # Decode the JSON response into a Perl Hash
        my $data = eval { decode_json($response) };
        if ($data && ref($data) eq 'HASH') {
            $version = $data->{version} // 'unknown';
            $uptime  = format_uptime($data->{timeStarted});
            # If we reached the API and got a version, the Router is considered UP
            $status  = ($version ne 'unknown') ? 1 : 0;
        }
    }

    # --- 5. Output for OEM ---
    # OEM Metric Extensions expect columns separated by a pipe (|)
    print join('|', $router_id, $address, $port, $status, $version, $uptime), "\n";
}

exit 0;
