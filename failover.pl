#!/usr/bin/env perl

Failover->new()->run();

exit;

package Failover;
use strict;
use warnings;
use Carp;
use English qw( -no_match_vars );
use Data::Dumper;
use Net::Ping;
use Time::HiRes;
use File::Temp;
use Term::ANSIColor;
use File::Temp qw( tempfile );

sub new {
    my $class = shift;
    return bless {}, $class;
}

sub run {
    my $self = shift;
    $OUTPUT_AUTOFLUSH = 1;
    $self->get_config();
    $self->verify_config();
    $self->get_user_confirmation();
    $self->run_failover();
    print "\nAll done.\n";
    exit;
}

sub run_failover {
    my $self = shift;
    exit unless $self->switch_ip();
    exit unless $self->promote_slave();
    exit unless $self->data_checks();
    return;
}

sub data_checks {
    my $self = shift;
    print "Data checks:\n";

    my $all_ok = 1;
    my @data_checks = sort grep { /^data-check-/ } keys %{ $self->{ 'cfg' } };
    for my $data_check ( @data_checks ) {
        my $C = $self->{'cfg'}->{ $data_check };
        my $title = $C->{'title'} || $data_check;
        $self->status( "  - $title" );
        my $result = $self->psql( $C->{'query'} );
        $result->{'stdout'} =~ s/\s*\z//;
        if ( $result->{'error_code'} ) {
            $all_ok = 0;
            $self->status_change( 'ERROR: %s : %s', $result->{'error_code'}, $result->{'stderr'}, );
        } elsif ( $result->{'stdout'} ne $C->{'result'} ) {
            $all_ok = 0;
            $self->status_change( 'ERROR: Unexpected return: [%s], expected [%s]', $result->{'stdout'}, $C->{'result'} );
        } else {
            $self->status_change( 'OK' );
        }
    }
    return $all_ok;
}

sub promote_slave {
    my $self = shift;

    # shortcut
    my $C = $self->{ 'cfg' }->{ 'db-promotion' };

    $self->status( 'Creating promotion trigger file' );

    my $touch_cmd = sprintf 'touch %s', quotemeta( $C->{ 'trigger-file' } );
    my $result = $self->ssh( $C->{ 'user' }, $C->{ 'host' }, $touch_cmd, 'ERROR' );
    return if $result->{ 'error_code' };

    $self->status( 'Checking that new pg is up and running in R/W mode' );
    my $start_time = time();
    my $end_at     = time() + ( $C->{ 'timeout' } || 60 );
    my $is_ok      = undef;
    while ( 1 ) {
        $result = $self->psql( 'CREATE TEMP TABLE failover_check ( i int4 )' );
        $is_ok = 1 if !$result->{ 'error_code' };
        last if $is_ok;
        last if time() > $end_at;
        sleep 1;
    }
    if ( $is_ok ) {
        $self->status_change( 'OK' );
        return 1;
    }
    $self->status_change( 'ERROR: PostgreSQL cannot be used on slave. Reason: %s', $result->{ 'stderr' } );
    return;
}

sub ping {
    my $self = shift;
    my ( $host, $port, $timeout ) = @_;

    my $p = Net::Ping->new( 'tcp', $timeout );
    $p->port_number( $port );
    my $ping_status = $p->ping( $host );
    $p->close();

    return $ping_status;
}

sub switch_ip {
    my $self = shift;

    # shortcut
    my $C = $self->{ 'cfg' }->{ 'ip-takeover' };

    $self->status( 'Checking db ip (%s)', $C->{ 'ip' } );

    my $ping_ok = $self->ping( $C->{ 'ip' }, $self->{ 'cfg' }->{ 'db-check' }->{ 'port' }, $C->{ 'initial-ping-timeout' } || 3 );

    if ( $ping_ok ) {
        $self->status_change( 'OK' );
    }
    else {
        $self->status_change( 'WARN: Remote host unreachable for ping' );
    }

    $self->status( 'Disabling IP (%s) on old host (%s)', $C->{ 'ip' }, $C->{ 'old' }->{ 'host' } );

    my $result = $self->ssh(
        $C->{ 'old' }->{ 'user' },
        $C->{ 'old' }->{ 'host' },
        $self->network_interface_change( 'down', $C->{ 'old' } ),
        $ping_ok ? 'ERROR' : 'WARN',
    );

    if ( $result->{ 'error_code' } ) {
        if ( $ping_ok ) {
            printf 'Cannot disable network interface on old host (%s). And the IP is pingable. Cannot continue.%s', $C->{ 'old' }->{ 'host' }, "\n";
            return;
        }
        printf 'Cannot disable network interface on old host (%s), but cannot ping the takeover IP either. Continuing, but make sure old host does not bring the interface up.%s',
            $C->{ 'old' }->{ 'host' }, "\n";
    }

    $self->status( 'Enabling IP (%s) on new host (%s)', $C->{ 'ip' }, $C->{ 'new' }->{ 'host' } );

    $result = $self->ssh(
        $C->{ 'new' }->{ 'user' },
        $C->{ 'new' }->{ 'host' },
        $self->network_interface_change( 'up', $C->{ 'new' } ),
        'ERROR',
    );

    if ( $result->{ 'error_code' } ) {
        printf 'Cannot bring up takeover IP interface on new host (%s).%s', $C->{ 'new' }->{ 'host' }, "\n";
        return;
    }

    $self->status( 'Checking db ip (%s) after takeover', $C->{ 'ip' } );
    $ping_ok = $self->ping( $C->{ 'ip' }, $self->{ 'cfg' }->{ 'db-check' }->{ 'port' }, $C->{ 'final-ping-timeout' } || 60 );
    if ( $ping_ok ) {
        $self->status_change( 'OK' );
        return 1;
    }
    $self->status_change( 'ERROR: Remote host unreachable for ping' );
    return;
}

sub psql {
    my $self = shift;
    my ( $query ) = @_;

    # Shortcut
    my $C = $self->{ 'cfg' }->{ 'db-check' };

    my @command = ();
    push @command, 'psql';
    push @command, '-qAtX';
    push @command, '-h', $self->{ 'cfg' }->{ 'ip-takeover' }->{ 'ip' };
    push @command, '-p', $C->{ 'port' } if $C->{ 'port' };
    push @command, '-U', $C->{ 'user' } if $C->{ 'user' };
    push @command, '-d', $C->{ 'database' } if $C->{ 'database' };
    push @command, '-c', $query;

    return $self->run_command( @command );
}

sub ssh {
    my $self = shift;
    my ( $user, $host, $command, $status_prefix ) = @_;

    my $ssh_account = defined $user ? $user . '@' . $host : $host;

    my $result = $self->run_command( 'ssh', $ssh_account, $command );
    $result->{ 'error_code' } = 'STDERR is not empty' if ( !$result->{ 'error_code' } ) && $result->{ 'stderr' };

    if ( $result->{ 'error_code' } ) {
        $self->status_change( '%s: %s', $status_prefix, $result->{ 'error_code' } );
        printf 'Real command: %s%s', $result->{ 'real_command' }, "\n";
    }
    else {
        $self->status_change( 'OK' );
    }

    printf "STDOUT:\n%s\n\n", $result->{ 'stdout' } if $result->{ 'stdout' };
    printf "STDERR:\n%s\n\n", $result->{ 'stderr' } if $result->{ 'stderr' };

    return $result;
}

sub network_interface_change {
    my $self = shift;
    my ( $direction, $config ) = @_;

    # So far we have only one possible "type" - ifupdown, but in future
    # there will be more, and then we'll need some logic in here to build
    # proper command.

    return sprintf 'if%s %s', $direction, quotemeta( $config->{ 'interface' } );
}

sub status {
    my $self = shift;
    my ( $msg, @args ) = @_;
    my $status_msg = sprintf( $msg, @args );
    printf '%-70s : ', $status_msg;
    $self->{ 'status_start_time' } = Time::HiRes::time();
    return;
}

sub status_change {
    my $self = shift;
    my ( $msg, @args ) = @_;
    my $now = Time::HiRes::time();
    my $status_msg = sprintf( $msg, @args );
    my $color =
          $status_msg =~ /^OK/    ? 'bold green'
        : $status_msg =~ /^WARN/  ? 'magenta'
        : $status_msg =~ /^ERROR/ ? 'bold red'
        :                           'reset';
    printf "%s%s%s (%.3fs)\n", color( $color ), $status_msg, color( 'reset' ), $now - $self->{ 'status_start_time' };
    return;
}

sub get_user_confirmation {
    my $self = shift;

    print " Settings:\n";
    print "===========\n\n";

    for my $section ( qw( ip-takeover db-promotion db-check ) ) {
        $self->show_configuration_section( $section, $self->{ 'cfg' }->{ $section }, 0 );
    }

    my @data_checks = sort grep { /^data-check-/ } keys %{ $self->{ 'cfg' } };
    if ( 0 != scalar @data_checks ) {
        print " Data checks:\n";
        print "==============\n";
        my $max_len = 0;
        for ( @data_checks ) {
            $max_len = length( $_ ) if length( $_ ) > $max_len;
        }
        $max_len -= 11;
        for my $check ( @data_checks ) {
            printf " %${max_len}s : %s\n", substr( $check, 11 ), $self->{ 'cfg' }->{ $check }->{ 'query' };
        }
        print "\n";
    }
    return if defined( $ENV{ 'FAILOVER' } ) && ( $ENV{ 'FAILOVER' } eq 'confirmed' );
    print 'Do you want to proceed (yes/no): ';
    my $answer = <STDIN>;
    return if $answer =~ m{\Ayes\r?\n};
    exit 1;
}

sub show_configuration_section {
    my $self = shift;
    my ( $title, $hash, $indent ) = @_;
    printf "%s- %s\n", " " x ( 2 * $indent ), $title;

    my @keys = sort keys %{ $hash };

    for my $key ( @keys ) {
        if ( 'HASH' eq ref $hash->{ $key } ) {
            $self->show_configuration_section( $key, $hash->{ $key }, $indent + 1 );
        }
        else {
            my $label_length = 15 - 2 * $indent;
            printf "%s  - %-${label_length}s : %s\n", " " x ( 2 * $indent ), $key, $hash->{ $key };
        }
    }
    print "\n" unless $indent;
    return;
}

sub verify_config {
    my $self = shift;

    for my $section ( qw( ip-takeover db-promotion db-check ) ) {
        next if defined $self->{ 'cfg' }->{ $section };
        $self->show_help_and_die( 'Section %s is missing from config file', $section );
    }

    my $c = $self->{ 'cfg' }->{ 'ip-takeover' };
    for my $machine ( qw( old new ) ) {
        for my $key ( qw( host type ) ) {
            next if defined $c->{ $machine }->{ $key };
            $self->show_help_and_die( 'Section ip-takeover is missing param %s-%s', $machine, $key );
        }
        if ( $c->{ $machine }->{ 'type' } eq 'ifupdown' ) {
            $self->show_help_and_die( 'Section ip-takeover is missing param %s-interface', $machine ) unless defined $c->{ $machine }->{ 'interface' };
        }
        else {
            $self->show_help_and_die( 'Bad %s-type in section ip-takeover.', $machine );
        }
    }
    $self->show_help_and_die( 'Section ip-takeover is missing param ip' ) unless defined $c->{ 'ip' };

    $c = $self->{ 'cfg' }->{ 'db-promotion' };
    for my $key ( qw( host trigger-file ) ) {
        next if defined $c->{ $key };
        $self->show_help_and_die( 'Section db-promotion is missing param %s', $key );
    }

    $c = $self->{ 'cfg' }->{ 'db-check' };
    for my $key ( qw( database port user ) ) {
        next if defined $c->{ $key };
        $self->show_help_and_die( 'Section db-check is missing param %s', $key );
    }

    for my $section ( grep { /^data-check-/ } keys %{ $self->{ 'cfg' } } ) {
        my $c = $self->{ 'cfg' }->{ $section };
        for my $key ( qw( query result ) ) {
            next if defined $c->{ $key };
            $self->show_help_and_die( 'Section %s is missing param %s', $section, $key );
        }
    }

    return;
}

sub get_config {
    my $self        = shift;
    my $config_file = $ARGV[ 0 ];
    $self->show_help_and_die() unless defined $config_file;

    open my $fh, '<', $config_file or $self->show_help_and_die( 'Cannot open given file (%s): %s', $config_file, $OS_ERROR );

    my $current_section = undef;
    while ( my $l = <$fh> ) {
        next if $l =~ /\A\s*#/;
        next if $l =~ /\A\s*\z/;

        $l =~ s/\s*\z//;

        if ( $l =~ m{\A\[(.*)\]\z} ) {
            $current_section = $1;
            next;
        }

        if ( $l =~ m{\A([a-zA-Z0-9_-]+)\s*=\s*(\S.*)\z} ) {
            my ( $param, $value ) = ( $1, $2 );
            if ( !defined $current_section ) {
                $self->show_help_and_die( 'Line: "%s" in config is before any section header!', $l );
            }
            if ( $param =~ s/^(old|new)-// ) {
                my $host = $1;
                $self->{ 'cfg' }->{ $current_section }->{ $host }->{ $param } = $value;
            }
            else {
                $self->{ 'cfg' }->{ $current_section }->{ $param } = $value;
            }
            next;
        }

        $self->show_help_and_die( 'Unknown line: "%s" in config!', $l );
    }
    close $fh;
    return;
}

sub run_command {
    my $self = shift;
    my @cmd  = @_;

    my $real_command = join( ' ', map { quotemeta } @cmd );

    my ( $stdout_fh, $stdout_filename ) = tempfile( "failover.$PROCESS_ID.stdout.XXXXXX" );
    my ( $stderr_fh, $stderr_filename ) = tempfile( "failover.$PROCESS_ID.stderr.XXXXXX" );

    $real_command .= sprintf ' 2>%s >%s', quotemeta $stderr_filename, quotemeta $stdout_filename;

    my $reply = {};
    $reply->{ 'real_command' } = $real_command;
    $reply->{ 'status' }       = system $real_command;
    local $/ = undef;
    $reply->{ 'stdout' } = <$stdout_fh>;
    $reply->{ 'stderr' } = <$stderr_fh>;

    close $stdout_fh;
    close $stderr_fh;

    unlink( $stdout_filename, $stderr_filename );

    if ( $CHILD_ERROR == -1 ) {
        $reply->{ 'error_code' } = $OS_ERROR;
    }
    elsif ( $CHILD_ERROR & 127 ) {
        $reply->{ 'error_code' } = sprintf "child died with signal %d, %s coredump\n", ( $CHILD_ERROR & 127 ), ( $CHILD_ERROR & 128 ) ? 'with' : 'without';
    }
    else {
        $reply->{ 'error_code' } = $CHILD_ERROR >> 8;
    }

    return $reply;
}

sub show_help_and_die {
    my $self = shift;
    my ( $msg, @args ) = @_;
    if ( defined $msg ) {
        printf STDERR $msg . "\n\n", @args;
    }
    print STDERR <<_END_OF_HELP_;
Syntax:
    $PROGRAM_NAME config_file

Config file should be full path, to readable file, with information about PostgreSQL cluster.

Example file content:
---------------------
[ip-takeover]
old-host=master
new-host=slave
old-type=ifupdown
old-interface=eth0:0
new-type=ifupdown
new-interface=eth0:0
ip=db

[db-promotion]
host=slave
user=postgres
trigger-file=/tmp/trigger.file

[db-check]
user=postgres
port=5432
database=postgres

[data-check-1]
query=select (now() - max(created_on)) < '5 minutes'::interval from objects
result=t

[data-check-2]
query=select (now() - max(logged_on)) < '15 minutes'::interval from users
result=t
---------------------

For more information about config file, please run:

    perldoc $PROGRAM_NAME

If you want to run without requiring confirmation, set shell environment variable

    FAILOVER

to value "confirmed". In bash, it can be done using:

    FAILOVER=confirmed $PROGRAM_NAME config_file
_END_OF_HELP_
    exit 1;
}

1;
