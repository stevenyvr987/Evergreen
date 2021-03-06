#!/usr/bin/perl
# ---------------------------------------------------------------
# Copyright (C) 2009 Equinox Software, Inc
# Author: Bill Erickson <erickson@esilibrary.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# ---------------------------------------------------------------
use strict;
use warnings;
use Getopt::Long;
use OpenSRF::System;
use OpenSRF::AppSession;
use OpenSRF::Utils::JSON;
use OpenSRF::Utils::Logger qw/$logger/;
use OpenSRF::EX qw(:try);
use OpenILS::Utils::Fieldmapper;
my $req_timeout = 10800;

# DEFAULT values

my $opt_lockfile      = '/tmp/action-trigger-LOCK';
my $opt_osrf_config   = '/openils/conf/opensrf_core.xml';
my $opt_custom_filter = '/openils/conf/action_trigger_filters.json';
my $opt_max_sleep     = 3600;  # default to 1 hour
my $opt_run_pending   = 0;
my $opt_debug_stdout  = 0;
my $opt_help          = 0;
my $opt_verbose;
my $opt_hooks;
my $opt_process_hooks = 0;
my $opt_granularity   = undef;
my $opt_gran_only     = undef;

(-f $opt_custom_filter) or undef($opt_custom_filter);   # discard default if no file exists

GetOptions(
    'max-sleep'        => \$opt_max_sleep,
    'osrf-config=s'    => \$opt_osrf_config,
    'run-pending'      => \$opt_run_pending,
    'hooks=s'          => \$opt_hooks,
    'granularity=s'    => \$opt_granularity,
    'granularity-only' => \$opt_gran_only,
    'process-hooks'    => \$opt_process_hooks,
    'debug-stdout'     => \$opt_debug_stdout,
    'custom-filters=s' => \$opt_custom_filter,
    'lock-file=s'      => \$opt_lockfile,
    'verbose'          => \$opt_verbose,
    'help'             => \$opt_help,
);

my $max_sleep = $opt_max_sleep;

#XXX need to figure out why this is required...
$opt_gran_only = $opt_granularity ? 1 : 0;

$opt_lockfile .= '.' . $opt_granularity if ($opt_granularity && $opt_gran_only);

# typical passive hook filters
my $hook_handlers = {

    # default overdue circulations
    'checkout.due' => {
        context_org => 'circ_lib',
        filter => {
            checkin_time => undef, 
            '-or' => [
                {stop_fines => ['MAXFINES', 'LONGOVERDUE']}, 
                {stop_fines => undef}
            ]
        }
    }
};

if ($opt_custom_filter) {
    open FILTERS, $opt_custom_filter or die "Cannot read custom filters at $opt_custom_filter";
    $hook_handlers = OpenSRF::Utils::JSON->JSON2perl(join('',(<FILTERS>)));
    close FILTERS;
}

sub help {
    print <<HELP;

$0 : Create and process action/trigger events

    --osrf-config=<config_file>
        OpenSRF core config file.  Defaults to:
            /openils/conf/opensrf_core.xml

    --custom-filters=<filter_file>
        File containing a JSON Object which describes any hooks that should
        use a user-defined filter to find their target objects.  Defaults to:
            /openils/conf/action_trigger_filters.json

    --run-pending
        Run pending events

    --process-hooks
        Create hook events

    --max-sleep=<seconds>
        When in process-hooks mode, wait up to <seconds> for the lock file to
        go away.  Defaults to 3600 (1 hour).

    --hooks=hook1[,hook2,hook3,...]
        Define which hooks to create events for.  If none are defined,
        it defaults to the list of hooks defined in the --custom-filters option.

    --granularity=<label>
        Run events with {label} granularity setting, or no granularity setting

    --granularity-only
        Used in combination with --granularity, prevents the running of events with no granularity setting

    --debug-stdout
        Print server responses to stdout (as JSON) for debugging

    --lock-file=<file_name>
        Lock file

    --help
        Show this help

    Examples:

        # To run all pending events.  This is what you tell CRON to run at
        # regular intervals
        perl $0 --osrf-config /openils/conf/opensrf_core.xml --run-pending

        # To batch create all "checkout.due" events
        perl $0 --osrf-config /openils/conf/opensrf_core.xml --hooks checkout.due

HELP
}


# create events for the specified hooks using the configured filters and context orgs
sub process_hooks {
    $opt_verbose and print "process_hooks: " . ($opt_process_hooks ? '(start)' : 'SKIPPING') . "\n";
    return unless $opt_process_hooks;

    my @hooks = ($opt_hooks) ? split(',', $opt_hooks) : keys(%$hook_handlers);
    my $ses = OpenSRF::AppSession->create('open-ils.trigger');

    for my $hook (@hooks) {
        my $config = $$hook_handlers{$hook};
        $opt_verbose and print "process_hooks: $hook " . ($config ? ($opt_granularity || '') : ' NO HANDLER') . "\n";
        $config or next;

        my $method = 'open-ils.trigger.passive.event.autocreate.batch';
        $method =~ s/passive/active/ if $config->{active};
        
        my $req = $ses->request($method, $hook, $config->{context_org}, $config->{filter}, $opt_granularity);

        my $debug_hook = "'$hook' and filter ".OpenSRF::Utils::JSON->perl2JSON($config->{filter});
        $logger->info("at_runner: creating events for $debug_hook");

        my @event_ids;
        while (my $resp = $req->recv(timeout => $req_timeout)) {
            push(@event_ids, $resp->content);
        }

        if(@event_ids) {
            $logger->info("at_runner: created ".scalar(@event_ids)." events for $debug_hook");
        } elsif($req->complete) {
            $logger->info("at_runner: no events to create for $debug_hook");
        } else {
            $logger->warn("at_runner: timeout occurred during event creation for $debug_hook");
        }
    }
}

sub run_pending {
    $opt_verbose and print "run_pending: " .
        ($opt_run_pending ?
            ($opt_granularity ?
                ( $opt_granularity . (
                    $opt_gran_only ?
                        ' ONLY' : 
                        ' and NON-GRANULAR'
                    )
                ) :
                'NON-GRANULAR'
            ) :
            'SKIPPING'
        ) . "\n";

    return unless $opt_run_pending;
    my $ses = OpenSRF::AppSession->create('open-ils.trigger');
    my $req = $ses->request('open-ils.trigger.event.run_all_pending' => $opt_granularity => $opt_gran_only);

    my $check_lockfile = 1;
    while (my $resp = $req->recv(timeout => $req_timeout)) {
        if ($check_lockfile && -e $opt_lockfile) {
            open LF, $opt_lockfile;
            my $contents = <LF>;
            close LF;
            unlink $opt_lockfile if ($contents == $$);
            $check_lockfile = 0;
        }
        $opt_debug_stdout and print OpenSRF::Utils::JSON->perl2JSON($resp->content) . "\n";
    }
}

help() and exit if $opt_help;
help() and exit unless ($opt_run_pending or $opt_process_hooks);

# check the lockfile
if (-e $opt_lockfile) {
    die "I'm already running with lockfile $opt_lockfile\n" unless ($opt_process_hooks or $opt_granularity);
    # sleeping loop if we're in --process-hooks mode
    while ($max_sleep >= 0 && sleep(1)) {
        last unless ( -e $opt_lockfile ); 
        $max_sleep--;
    }
}

# there's a tiny race condition here ... oh well
die "Someone else has been holding the lockfile $opt_lockfile for at least $opt_max_sleep. Giving up now ...\n" if (-e $opt_lockfile);

# set the lockfile
open(F, ">$opt_lockfile") or die "Unable to open lockfile $opt_lockfile for writing\n";
print F $$;
close F;

try {
	OpenSRF::System->bootstrap_client(config_file => $opt_osrf_config);
	Fieldmapper->import(IDL => OpenSRF::Utils::SettingsClient->new->config_value("IDL"));
    process_hooks();
    run_pending();
} otherwise {
    my $e = shift;
    warn "$e\n";
};

if (-e $opt_lockfile) {
    open LF, $opt_lockfile;
    my $contents = <LF>;
    close LF;
    unlink $opt_lockfile if ($contents == $$);
}
