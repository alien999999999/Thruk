package Thruk::Backend::Manager;

use strict;
use warnings;
use Carp;
use Digest::MD5 qw(md5_hex);
use Data::Page ();
use Data::Dumper;
use Scalar::Util qw/ looks_like_number /;
use Encode qw/encode_utf8/;
use Time::HiRes qw/gettimeofday tv_interval/;
use Thruk::Utils ();
use Thruk::Pool::Simple ();
use Thruk::Config ();
use Thruk::Backend::Peer ();
use Thruk::Backend::Pool ();
use Thruk::Utils::IO ();
#use Thruk::Timer qw/timing_breakpoint/;

our $AUTOLOAD;

=head1 NAME

Thruk::Backend::Manager - Manager of backend connections

=head1 DESCRIPTION

Manager of backend connections

=head1 METHODS

=cut

##########################################################

=head2 new

create new manager

=cut

sub new {
    my( $class ) = @_;
    my $self = {
        'initialized'         => 0,
        'state_hosts'         => {},
        'local_hosts'         => {},
        'backends'            => [],
        'backend_debug'       => 0,
        'sections'            => {},
        'failed_backends'     => {},
        'by_key'              => {},
        'by_name'             => {},
        'last_program_starts' => {},
    };
    bless $self, $class;
    return $self;
}

##########################################################

=head2 init

initialize this model

=cut

sub init {
    my( $self, %options ) = @_;

    for my $key (%options) {
        $self->{$key} = $options{$key};
    }

    return if $self->{'initialized'} == 1;

    # retain order
    $self->{'backends'} = [];
    for my $key (@{$Thruk::Backend::Pool::peer_order}) {
        push @{$self->{'backends'}}, $Thruk::Backend::Pool::peers->{$key};
    }

    # check if we initialized at least one backend
    return if scalar @{ $self->{'backends'} } == 0;

    for my $peer (@{$self->get_peers(1)}) {
        $self->{'by_key'}->{$peer->{'key'}}   = $peer;
        $self->{'by_name'}->{$peer->{'name'}} = $peer;

        if($peer->{'state_host'}) {
            $self->{'state_hosts'}->{$peer->{'key'}} = { source => $peer->{'state_host'} };
        } else {
            $self->{'local_hosts'}->{$peer->{'key'}} = 1;
        }
        my($subsection,$section) = split(/\//mx, $peer->{'section'}, 2);
        if(!$section) {
            $section    = $subsection;
            $subsection = 'Default';
        }
        if(!defined $self->{'sections'}->{$subsection}->{$section}->{$peer->{'name'}}) {
            $self->{'sections'}->{$subsection}->{$section}->{$peer->{'name'}} = [];
        }
        push @{$self->{'sections'}->{$subsection}->{$section}->{$peer->{'name'}}}, $peer;
    }

    $self->{'initialized'} = 1;

    return 1;
}


##########################################################

=head2 disable_hidden_backends

  disable_hidden_backends()

returns list of hidden backends

=cut

sub disable_hidden_backends {
    my($self, $disabled_backends, $display_too) = @_;

    $disabled_backends = {} unless $disabled_backends;
    my $peers          = $self->get_peers();

    # only hide them, if we have more than one
    return $disabled_backends if scalar @{$peers} <= 1;

    for my $peer (@{$peers}) {
        if(defined $peer->{'hidden'} and $peer->{'hidden'} == 1) {
            $disabled_backends->{$peer->{'key'}} = 2;
        }
        if($display_too and defined $peer->{'display'} and $peer->{'display'} == 0) {
            $disabled_backends->{$peer->{'key'}} = 2;
        }
    }
    return $disabled_backends;
}

##########################################################

=head2 get_peers

  get_peers([$all])

returns all configured peers (except config-only)

=cut

sub get_peers {
    my($self, $all) = @_;
    return \@{$self->{'backends'}} if $all;

    my @peers;
    for my $b (@{$self->{'backends'}}) {
        push @peers, $b if $b->{'addr'};
    }
    return \@peers;
}

##########################################################

=head2 get_peer_by_key

  get_peer_by_key()

returns peer by key

=cut

sub get_peer_by_key {
    my($self, $key) = @_;
    my $peer = $self->{'by_key'}->{$key};
    return $peer if $peer;
    $peer = $self->{'by_name'}->{$key};
    return $peer if $peer;
    return;
}

##########################################################

=head2 get_peer_by_name

  get_peer_by_name()

returns peer by name

=cut

sub get_peer_by_name {
    my($self, $name) = @_;
    return $self->{'by_name'}->{$name};
    return;
}

##########################################################

=head2 peer_key

  peer_key()

returns all peer keys

=cut

sub peer_key {
    my($self) = @_;
    my @keys;
    for my $peer ( @{ $self->get_peers() } ) {
        push @keys, $peer->{'key'};
    }
    return \@keys;
}

##########################################################

=head2 sections

  sections()

returns all sections

=cut

sub sections {
    my($self) = @_;
    return $self->{'sections'};
}

##########################################################

=head2 disable_backend

  disable_backend(<key>)

disable backend by key

=cut

sub disable_backend {
    my($self, $key) = @_;

    my $peer = $self->get_peer_by_key($key);
    if( defined $peer ) {
        $peer->{'enabled'} = 0;
    }
    return;
}

##########################################################

=head2 enable_backend

  enable_backend(<key>)

ensable backend by key

=cut

sub enable_backend {
    my($self, $key) = @_;

    my $peer = $self->get_peer_by_key($key);
    if( defined $peer ) {
        $peer->{'enabled'} = 1;
    }
    return;
}

##########################################################

=head2 disable_backends

  disable_backends(<keys_hash>)

disabled backend by key hash

=cut

sub disable_backends {
    my($self, $keys) = @_;

    if( defined $keys ) {
        for my $key ( keys %{$keys} ) {
            if( $keys->{$key} !~ m/^\d+$/mx or $keys->{$key} == 2 or $keys->{$key} == 3 ) {
                $self->disable_backend($key);
            }
        }
    }
    else {
        for my $peer ( @{ $self->get_peers() } ) {
            $peer->{'enabled'} = 0;
        }
    }
    return;
}

##########################################################

=head2 enable_backends

  enable_backends(<keys>)

enables all backends

=cut

sub enable_backends {
    my($self, $keys) = @_;

    if( defined $keys ) {
        if(ref $keys eq 'ARRAY') {
            my %hash = map { $_ => 1 } @{$keys};
            $keys = \%hash;
        }
        elsif(ref $keys eq '') {
            $keys = { $keys => 1 };
        }

        for my $key ( keys %{$keys} ) {
            $self->enable_backend($key);
        }
    }
    else {
        for my $peer ( @{ $self->get_peers() } ) {
            $peer->{'enabled'} = 1;
        }
    }
    return;
}

##########################################################

=head2 get_default_backends

  get_default_backends()

returns all default backends

=cut

sub get_default_backends {
    my($self) = @_;
    my $defaults = [];
    for my $peer ( @{ $self->get_peers() } ) {
        if(!$peer->{'hidden'}) {
            push @{$defaults}, $peer->{'key'};
        }
    }
    return($defaults);
}

##########################################################

=head2 get_scheduling_queue

  get_scheduling_queue

returns the scheduling queue

=cut
sub get_scheduling_queue {
    my($self, $c, %options) = @_;

    my($services) = $self->get_services(filter => [Thruk::Utils::Auth::get_auth_filter($c, 'services'),
                                                 { '-or' => [{ 'active_checks_enabled' => '1' },
                                                            { 'check_options' => { '!=' => '0' }}]
                                                 }
                                                 ]
                                      );
    my($hosts)    = $self->get_hosts(filter => [Thruk::Utils::Auth::get_auth_filter($c, 'hosts'),
                                              { '-or' => [{ 'active_checks_enabled' => '1' },
                                                         { 'check_options' => { '!=' => '0' }}]
                                              }
                                              ],
                                    options => { rename => { 'name' => 'host_name' }, callbacks => { 'description' => 'empty_callback' } }
                                    );

    my $queue = [];
    if(defined $services) {
        push @{$queue}, @{$services};
    }
    if(defined $hosts) {
        push @{$queue}, @{$hosts};
    }
    $queue = $self->_sort( $queue, $options{'sort'} );
    $self->_page_data( $c, $queue );
    return $queue;
}

########################################

=head2 get_performance_stats

  get_performance_stats

wrapper around get_performance_stats

=cut

sub get_performance_stats {
    my $self = shift;
    # inject last_program_starts
    my $args = \@_;
    push @{$args}, ('last_program_starts', $self->{'last_program_starts'});
    return $self->_do_on_peers('get_performance_stats', \@_ );
}

########################################

=head2 get_hosts

  get_hosts

wrapper around get_hosts

=cut

sub get_hosts {
    my $self = shift;
    # inject last_program_starts
    my $args = \@_;
    push @{$args}, ('last_program_starts', $self->{'last_program_starts'});
    return $self->_do_on_peers('get_hosts', \@_ );
}

########################################

=head2 get_services

  get_services

wrapper around get_services

=cut

sub get_services {
    my $self = shift;
    # inject last_program_starts
    my $args = \@_;
    push @{$args}, ('last_program_starts', $self->{'last_program_starts'});
    return $self->_do_on_peers('get_services', \@_ );
}

########################################

=head2 get_contactgroups_by_contact

  get_contactgroups_by_contact

returns a list of contactgroups by contact

=cut

sub get_contactgroups_by_contact {
    my( $self, $c, $username, $reload ) = @_;

    my $cached_data = {};
    $cached_data    = $c->cache->get->{'users'}->{$username} if defined $username;
    if( !$reload && defined $cached_data->{'contactgroups'} ) {
        return $cached_data->{'contactgroups'};
    }

    my $data = $self->_do_on_peers( "get_contactgroups_by_contact", [ $username ], undef, $self->get_default_backends());
    my $contactgroups = {};
    for my $group (@{$data}) {
        $contactgroups->{$group->{'name'}} = 1;
    }

    $cached_data->{'contactgroups'} = $contactgroups;
    $c->cache->set('users', $username, $cached_data);
    return $contactgroups;
}

########################################

=head2 get_hostgroup_names_from_hosts

  get_hostgroup_names_from_hosts

returns a list of hostgroups but get list from hosts in order to
respect permissions

=cut

sub get_hostgroup_names_from_hosts {
    my $self = shift; # keep this
    if(scalar @_ == 0) { return $self->get_hostgroup_names(); }
    my $hosts = $self->get_hosts( @_, 'columns', ['groups'] );
    my $groups = {};
    for my $host (@{$hosts}) {
        for my $group (@{$host->{'groups'}}) {
            $groups->{$group} = 1;
        }
    }
    my @sorted = sort keys %{$groups};
    return \@sorted;
}

########################################

=head2 get_servicegroup_names_from_services

  get_servicegroup_names_from_services

returns a list of servicegroups but get list from services in order to
respect permissions

=cut

sub get_servicegroup_names_from_services {
    my $self = shift; # keep this
    if(scalar @_ == 0) { return $self->get_servicegroup_names(); }
    my $services = $self->get_services( @_, 'columns', ['groups'] );
    my $groups = {};
    for my $service (@{$services}) {
        for my $group (@{$service->{'groups'}}) {
            $groups->{$group} = 1;
        }
    }
    my @sorted = sort keys %{$groups};
    return \@sorted;
}

########################################

=head2 reconnect

  reconnect

runs reconnect on all peers

=cut

sub reconnect {
    my $self = shift; # keep this
    my $c = $Thruk::Backend::Manager::c;
    eval {
        $self->_do_on_peers( 'reconnect', \@_);
    };
    $c->log->debug($@) if $@;
    return 1;
}

########################################

=head2 expand_command

  expand_command

expand a command line with host/service data

=cut

sub expand_command {
    my( $self, %data ) = @_;
    croak("no host")    unless defined $data{'host'};
    my $host     = $data{'host'};
    my $service  = $data{'service'};
    my $command  = $data{'command'};
    my $source   = $data{'source'};

    my $obj          = $host;
    my $command_name = $host->{'check_command'};
    if(defined $service) {
        $command_name = $service->{'check_command'};
        $obj          = $service;
    }

    # different source?
    if(defined $source and $source ne 'check_command') {
        $source  = uc($source);
        $source  =~ s/^_//mx;
        my $vars = Thruk::Utils::get_custom_vars($obj);
        $command_name = $vars->{$source} || '';
    }

    my($name, @com_args) = split(/(?<!\\)!/mx, $command_name, 255);

    # it is possible to define hosts without a command
    if(!defined $name or $name =~ m/^\s*$/mx) {
        my $return = {
            'line'          => 'no command defined',
            'line_expanded' => '',
            'note'          => '',
        };
        return $return;
    }

    # get command data
    my $expanded;
    if(defined $command) {
        $expanded = $command->{'line'};
    } else {
        my $commands = $self->get_commands( filter => [ { 'name' => $name } ] );
        $expanded = $commands->[0]->{'line'};
    }

    my $rc;
    eval {
        ($expanded,$rc) = $self->_replace_macros({string => $expanded, host => $host, service => $service, args => \@com_args });
    };

    # does it still contain macros?
    my $note = "";
    if($@) {
        $note = $@;
        $note =~ s/\s+at\s+\/.*?$//mx;
    } elsif(!$rc) {
        $note = "could not expand all macros!";
    }

    my $return = {
        'line'          => $command_name,
        'line_expanded' => $expanded,
        'note'          => $note,
    };
    return $return;
}

########################################

=head2 set_backend_state_from_local_connections

  set_backend_state_from_local_connections

enables/disables remote backends based on a state from local instances

=cut

sub set_backend_state_from_local_connections {
    my( $self, $disabled, $safe, $cached_data ) = @_;
    $safe = 0 unless defined $safe;

    my $c = $Thruk::Backend::Manager::c;

    return $disabled unless scalar keys %{$self->{'local_hosts'}} >= 1;
    return $disabled unless scalar keys %{$self->{'state_hosts'}} >= 1;

    $c->stats->profile( begin => "set_backend_state_from_local_connections() " );

    my $options = [
        'backend', [ keys %{$self->{'local_hosts'}} ],
        'columns', [qw/address name alias state/],
    ];

    my @filter;
    for my $host (values %{$self->{'state_hosts'}}) {
        push @filter, { '-or' => [ { name    => { '=' => $host->{'source'} } },
                                   { alias   => { '=' => $host->{'source'} } },
                                   { address => { '=' => $host->{'source'} } },
                      ]};
    }
    push @{$options}, 'filter', [ Thruk::Utils::combine_filter( '-or', \@filter ) ];


    for(1..3) {
        # reset failed states, otherwise retry would be useless
        $self->reset_failed_backends();

        eval {
            my $data;
            if($safe == 2) {
                $data = $cached_data->{'local_states'};
            }
            $data = $self->_do_on_peers( "get_hosts", $options ) unless defined $data;
            for my $host (@{$data}) {
                # find matching keys
                my $key;
                for my $state_key (keys %{$self->{'state_hosts'}}) {
                    my $name = $self->{'state_hosts'}->{$state_key}->{'source'};
                    next unless $name;
                    $key = $state_key if $host->{'name'}    eq $name;
                    $key = $state_key if $host->{'address'} eq $name;
                    $key = $state_key if $host->{'alias'}   eq $name;

                    next unless defined $key;
                    next if defined $disabled->{$key} and $disabled->{$key} == 2;

                    $self->{'state_hosts'}->{$key}->{'name'} = $host->{'name'};

                    my $peer = $self->get_peer_by_key($key);

                    if($host->{'state'} == 0) {
                        $c->log->debug($key." -> enabled by local state check (".$host->{'name'}.")");
                        $peer->{'enabled'}    = 1 unless $peer->{'enabled'} == 2; # not for hidden ones
                        $peer->{'runnning'}   = 1;
                        $peer->{'last_error'} = 'UP: peer check via local instance(s) returned state: '.Thruk::Utils::translate_host_status($host->{'state'});
                    } else {
                        $c->log->debug($key." -> disabled by local state check (".$host->{'name'}.")");
                        $self->disable_backend($key);
                        $peer->{'runnning'}   = 0;
                        $peer->{'last_error'} = 'ERROR: peer check via local instance(s) returned state: '.Thruk::Utils::translate_host_status($host->{'state'});
                        $disabled->{$key}     = 1;
                    }
                }
            }
            $cached_data->{'local_states'} = $data;
        };
        if($@) {
            sleep(1);
        } else {
            last;
        }
    }
    # log errors only once
    if($@) {
        return $disabled if $safe;
        $c->log->error("failed setting states by local check");
        $c->log->debug($@);
    }

    $c->stats->profile( end => "set_backend_state_from_local_connections() " );

    return $disabled;
}

########################################

=head2 logcache_stats

  logcache_stats($c)

return logcache statistics

=cut

sub logcache_stats {
    my($self, $c, $with_dates) = @_;
    return unless defined $c->config->{'logcache'};

    my $type = 'mongodb';
    $type = 'mysql' if $c->config->{'logcache'} =~ m/^mysql/mxi;
    my(@stats);
    if($type eq 'mysql') {
        @stats = Thruk::Backend::Provider::Mysql->_log_stats($c);
    } else {
        @stats = Thruk::Backend::Provider::Mongodb->_log_stats($c);
    }
    my $stats = Thruk::Utils::array2hash(\@stats, 'key');

    if($with_dates) {
        for my $key (keys %{$stats}) {
            my $peer  = $self->get_peer_by_key($key);
            my $table = $type eq 'mongodb' ? 'logs_'.$key : undef;
            my($start, $end) = @{$peer->{'logcache'}->_get_logs_start_end('collection' => $table)};
            $stats->{$key}->{'start'} = $start;
            $stats->{$key}->{'end'}   = $end;
        }
    }

    # clean up connections
    close_logcache_connections($c);

    return $stats;
}

########################################

=head2 renew_logcache

  renew_logcache($c, [$noforks])

update the logcache

=cut

sub renew_logcache {
    my($self, $c, $noforks) = @_;
    $noforks = 0 unless defined $noforks;
    return unless defined $c->config->{'logcache'};
    eval {
        return $self->_renew_logcache($c, $noforks);
    };
    if($@) {
        $c->log->error($@);
        $c->stash->{errorMessage}     = "Logfilecache Unavailable";
        $c->stash->{errorDescription} = $@;
        $c->stash->{errorDescription} =~ s/\s+at\s+.*?\.pm\s+line\s+\d+\.//gmx;
        return $c->detach('/error/index/99');
    }
    return;
}

########################################

=head2 _renew_logcache

  _renew_logcache($c)

update the logcache (internal sub)

=cut

sub _renew_logcache {
    my $self = shift;
    my($c, $noforks) = @_;

    # check if this is the first import at all
    # and do a external import in that case
    #my($get_results_for, $arg_array, $arg_hash)...
    my($get_results_for, undef, undef) = $self->select_backends('renew_logcache', \@_);
    my $check = 0;
    $self->{'logcache_checked'} = {} unless defined $self->{'logcache_checked'};
    for my $key (@{$get_results_for}) {
        if(!defined $self->{'logcache_checked'}->{$key}) {
            $self->{'logcache_checked'}->{$key} = 1;
            $check = 1;
        }
    }

    if($check) {
        $c->stash->{'backends'} = $get_results_for;
        my $type = 'mongodb';
        $type = 'mysql' if $c->config->{'logcache'} =~ m/^mysql/mxi;
        my $stats = $self->logcache_stats($c);
        my $backends2import = [];
        for my $key (@{$get_results_for}) {
            push @{$backends2import}, $key unless defined $stats->{$key};
        }
        if(scalar @{$backends2import} > 0) {
            return Thruk::Utils::External::perl($c, { expr      => 'Thruk::Backend::Provider::'.(ucfirst $type).'->_import_logs($c, "import")',
                                                      message   => 'please stand by while your initial logfile cache will be created...',
                                                      forward   => $c->request->uri(),
                                                      backends  => $backends2import,
                                                      nofork    => $noforks,
                                                    });
        }
        $self->_do_on_peers( 'renew_logcache', \@_, 1);
    }
    return;
}

########################################

=head2 close_logcache_connections

  close_logcache_connections($c)

close all logcache connections

=cut
sub close_logcache_connections {
    my($c) = @_;
    # clean up connections
    for my $key (@{$c->stash->{'backends'}}) {
        my $peer = $c->{'db'}->get_peer_by_key($key);
        $peer->{'logcache'}->_disconnect() if $peer->{'logcache'};
    }
    return;
}


########################################

=head2 _get_macros

  _get_macros

returns a hash of macros

=cut

sub _get_macros {
    my $self    = shift;
    my $args    = shift;
    my $macros  = shift || {};

    my $host    = $args->{'host'};
    my $service = $args->{'service'};

    # arguments
    my $x = 1;
    for my $arg (@{$args->{'args'}}) {
        $macros->{'$ARG'.$x.'$'} = $arg;
        $x++;
    }

    # user macros...
    unless(defined $args->{'skip_user'}) {
        $self->_set_user_macros($host->{'peer_key'}, $macros);
    }

    # host macros
    if(defined $host) {
        $self->_set_host_macros($host, $macros);
    }

    # service macros
    if(defined $service) {
        $self->_set_service_macros($service, $macros);
    }

    # date macros
    my $now           = time();
    my $time          = Thruk::Utils::format_date($now, '%H:%M:%S' );
    my $date          = Thruk::Utils::format_date($now, '%Y-%m-%d' );
    my $longdatetime  = Thruk::Utils::format_date($now, '%a %b %e %H:%M:%S %Z %Y' );
    my $shortdatetime = $date." ".$time;
    $macros->{'$SHORTDATETIME$'} = $shortdatetime;
    $macros->{'$LONGDATETIME$'}  = $longdatetime;
    $macros->{'$DATE$'}          = $date;
    $macros->{'$TIME$'}          = $time;
    $macros->{'$TIMET$'}         = $now;

    return $macros;
}

########################################

=head2 _replace_macros

  _replace_macros

returns a result for a sub called on all peers

=cut

sub _replace_macros {
    my( $self, $args ) = @_;

    my $string  = $args->{'string'};
    my $macros  = $self->_get_macros($args);

    return $self->_get_replaced_string($string, $macros);
}

########################################

=head2 _get_replaced_string

  _get_replaced_string

returns replaced string

=cut

sub _get_replaced_string {
    my( $self, $string, $macros, $skip_args ) = @_;
    my $rc  = 1;
    my $res = "";
    return($res, $rc) unless defined $string;
    for my $block (split/(\$[\w\d_:]+\$)/mx, $string) {
        next if $block eq '';
        if(substr($block,0,1) eq '$' and substr($block, -1) eq '$') {
            if(defined $macros->{$block} or $block =~ m/^\$ARG\d+\$/mx) {
                my $replacement = $macros->{$block};
                $replacement    = '' unless defined $replacement;
                if(!$skip_args and $block =~ m/\$ARG\d+\$$/mx) {
                    my $sub_rc;
                    ($replacement, $sub_rc) = $self->_get_replaced_string($replacement, $macros, 1);
                    $rc = 0 unless $sub_rc;
                }
                $block = $replacement;
            } else {
                $rc = 0;
            }
        }
        $res .= $block;
    }
    ## no critic
    if (defined $macros->{'$_SERVICEOBFUSCATE_ME$'}) {
        eval {
            $res =~ s/$macros->{'$_SERVICEOBFUSCATE_ME$'}/\*\*\*/g;
        };
    }
    if (defined $macros->{'$_HOSTOBFUSCATE_ME$'}) {
        eval {
            $res =~ s/$macros->{'$_HOSTOBFUSCATE_ME$'}/\*\*\*/g;
        };
    }
    ## use critic

    return($res, $rc);
}
########################################

=head2 _set_host_macros

  _set_host_macros

set host macros

=cut

sub _set_host_macros {
    my( $self, $host, $macros ) = @_;
    my $c = $Thruk::Backend::Manager::c;

    # normal host macros
    $macros->{'$HOSTADDRESS$'}       = (defined $host->{'host_address'})         ? $host->{'host_address'}         : $host->{'address'};
    $macros->{'$HOSTNAME$'}          = (defined $host->{'host_name'})            ? $host->{'host_name'}            : $host->{'name'};
    $macros->{'$HOSTALIAS$'}         = (defined $host->{'host_alias'})           ? $host->{'host_alias'}           : $host->{'alias'};
    $macros->{'$HOSTSTATEID$'}       = (defined $host->{'host_state'})           ? $host->{'host_state'}           : $host->{'state'};
    $macros->{'$HOSTLATENCY$'}       = (defined $host->{'host_latency'})         ? $host->{'host_latency'}         : $host->{'latency'};
    $macros->{'$HOSTOUTPUT$'}        = (defined $host->{'host_plugin_output'})   ? $host->{'host_plugin_output'}   : $host->{'plugin_output'};
    $macros->{'$HOSTPERFDATA$'}      = (defined $host->{'host_perf_data'})       ? $host->{'host_perf_data'}       : $host->{'perf_data'};
    $macros->{'$HOSTATTEMPT$'}       = (defined $host->{'host_current_attempt'}) ? $host->{'host_current_attempt'} : $host->{'current_attempt'};
    $macros->{'$HOSTCHECKCOMMAND$'}  = (defined $host->{'host_check_command'})   ? $host->{'host_check_command'}   : $host->{'check_command'};
    $macros->{'$HOSTSTATE$'}         = $c->config->{'nagios'}->{'host_state_by_number'}->{$macros->{'$HOSTSTATEID$'}};

    my $prefix = (defined $host->{'host_custom_variable_names'}) ? 'host_' : '';

    # host user macros
    my $x = 0;
    for my $key (@{$host->{$prefix.'custom_variable_names'}}) {
        $macros->{'$_HOST'.$key.'$'}  = $host->{$prefix.'custom_variable_values'}->[$x];
        $x++;
    }

    return $macros;
}

########################################

=head2 _set_service_macros

  _set_service_macros

sets service macros

=cut

sub _set_service_macros {
    my( $self, $service, $macros ) = @_;
    my $c = $Thruk::Backend::Manager::c;

    # normal service macros
    $macros->{'$SERVICEDESC$'}         = $service->{'description'};
    $macros->{'$SERVICESTATEID$'}      = $service->{'state'};
    $macros->{'$SERVICESTATE$'}        = $c->config->{'nagios'}->{'service_state_by_number'}->{$service->{'state'}};
    $macros->{'$SERVICELATENCY$'}      = $service->{'latency'};
    $macros->{'$SERVICEOUTPUT$'}       = $service->{'plugin_output'};
    $macros->{'$SERVICEPERFDATA$'}     = $service->{'perf_data'};
    $macros->{'$SERVICEATTEMPT$'}      = $service->{'current_attempt'};
    $macros->{'$SERVICECHECKCOMMAND$'} = $service->{'check_command'};

    # service user macros...
    my $x = 0;
    for my $key (@{$service->{'custom_variable_names'}}) {
        $macros->{'$_SERVICE'.$key.'$'} = $service->{'custom_variable_values'}->[$x];
        $x++;
    }

    return $macros;
}
########################################

=head2 _do_on_peers

  _do_on_peers($function, $options)

returns a result for a sub called for all peers

  $function is the name of the sub called on our peers
  $options is a hash:
  {
    backend => []     # array of backends where this sub should be called
  }

=cut

sub _do_on_peers {
    my( $self, $function, $arg, $force_serial, $backends) = @_;
    my $c = $Thruk::Backend::Manager::c;

    $c->stats->profile( begin => '_do_on_peers('.$function.')');

    my($get_results_for, $arg_array, $arg_hash) = $self->select_backends($function, $arg);
    $get_results_for = $backends if $backends;
    my %arg = %{$arg_hash};
    $arg = $arg_array;

    # send query to selected backends
    my $selected_backends = scalar @{$get_results_for};
    $c->stash->{'num_selected_backends'} = $selected_backends;
    my($result, $type, $totalsize) = $self->_get_result($get_results_for, $function, $arg, $force_serial);
    #&timing_breakpoint('_get_result: '.$function);
    if(!defined $result and $selected_backends != 0) {
        # we don't need a full stacktrace for known errors
        my $err = $@; # only set if there is exact one backend
        if($err =~ m/(couldn't\s+connect\s+to\s+server\s+[^\s]+)/mx) {
            die($1);
        }
        # failed to open socket /tmp/live.sock: No such file or directory
        elsif($err =~ m|(failed\s+to\s+open\s+socket\s+[^:]+:.*?)\s+at\s+|mx) {
            confess($1);
        }
        # failed to connect at .../Class/Lite.pm line 245.
        elsif($err =~ m|(failed\s+to\s+connect)\s+at\s+|mx) {
            die($1);
        }
        elsif($err =~ m|(hit\s\+.*?timeout\s+on.*?)\s+at\s+|mx) {
            die($1);
        }
        elsif($err =~ m|^(DBI\s+.*?)\s+at\s+|mx) {
            die($1);
        }
        elsif($err =~ m|(^\d{3}:\s+.*?)\s+at\s+|mx) {
            die($1);
        }
        elsif($err) {
            die($err);
        } else {
            # multiple backends and all fail
            # die with a small error for know, usually an empty result means that
            # none of our backends were reachable
            die('undefined result');
            #local $Data::Dumper::Deepcopy = 1;
            #my $msg = "Error in _do_on_peers: '".($err ? $err : 'undefined result')."'\n";
            #for my $b (@{$get_results_for}) {
            #    $msg   .= $b.": ".($c->stash->{'failed_backends'}->{$b} || '')."\n";
            #}
            #$msg   .= "called as '".(ref $function ? Dumper($function) : $function)."\n";
            #$msg   .= "with args: ".Dumper(\%arg);
            #confess($msg);
        }
    }
    $type = '' unless defined $type;
    $type = lc $type;

    # extract some extra data
    if($function eq 'get_processinfo') {
        # update configtool settings
        # and update last_program_starts
        for my $key (keys %{$result}) {
            my $res = $result->{$key}->{$key};
            next unless defined $res;
            next unless defined $res->{'configtool'};
            my $peer = $self->get_peer_by_key($key);
            # do not overwrite local configuration with remote configtool settings
            # only use remote if the local one is empty
            next if(scalar keys %{$peer->{'configtool'}} != 0 and !$peer->{'configtool'}->{'remote'});
            $peer->{'configtool'} = { remote => 1 };
            for my $attr (keys %{$res->{'configtool'}}) {
                $peer->{'configtool'}->{$attr} = $res->{'configtool'}->{$attr};
            }
        }
    }

    # howto merge the answers?
    my $data;
    if( $type eq 'file' ) {
        $data = $result;
    }
    elsif( $type eq 'uniq' ) {
        $data = $self->_merge_answer( $result, $type );
        my %seen = ();
        my @uniq = sort( grep { !$seen{$_}++ } @{$data} );
        $data = \@uniq;
    }
    elsif ( $type eq 'stats' ) {
        $data = $self->_merge_stats_answer($result);
    }
    elsif ( $type eq 'sum' ) {
        $data = $self->_sum_answer($result);
    }
    elsif ( $function eq 'get_hostgroups' ) {
        $data = $self->_merge_hostgroup_answer($result);
    }
    elsif ( $function eq 'get_servicegroups' ) {
        $data = $self->_merge_servicegroup_answer($result);
    }
    else {
        $data = $self->_merge_answer( $result, $type );
    }

    # additional data processing, paging, sorting and limiting
    if(scalar keys %arg > 0) {
        if( $arg{'remove_duplicates'} ) {
            $data = $self->_remove_duplicates($data);
            $totalsize = scalar @{$data};
        }

        if( $arg{'sort'} ) {
            if($type ne 'sorted' or scalar keys %{$result} > 1) {
                $data = $self->_sort( $data, $arg{'sort'} );
            }
        }

        if( $arg{'limit'} ) {
            $data = $self->_limit( $data, $arg{'limit'} );
        }

        if( $arg{'pager'} ) {
            $data = $self->_page_data( undef, $data, undef, $totalsize );
        }
    }

    $data = $self->_set_result_defaults($function, $data);

    #&timing_breakpoint('_get_result complete: '.$function);

    $c->stats->profile( end => '_do_on_peers('.$function.')');

    return $data;
}

########################################

=head2 select_backends

  select_backends($function, [$args])

select backends we want to run functions on

=cut

sub select_backends {
    my( $self, $function, $arg) = @_;
    my $c = $Thruk::Backend::Manager::c;

    # do we have to send the query to all backends or just a few?
    my(%arg, $backends);
    if(     ( $function =~ m/^get_/mxo or $function eq 'send_command')
        and ref $arg eq 'ARRAY'
        and scalar @{$arg} % 2 == 0 )
    {
        %arg = @{$arg};

        if( $arg{'backend'} ) {
            if(ref $arg{'backend'} eq 'ARRAY') {
                for my $b (@{$arg{'backend'}}) {
                    $backends->{$b} = 1;
                }
            } else {
                for my $b (split(/,/mxo,$arg{'backend'})) {
                    $backends->{$b} = 1;
                }
            }
        }
        if(exists $arg{'pager'}) {
            delete $arg{'pager'};
            if($c->stash->{'use_pager'}) {
                $arg{'pager'} = {
                    entries  => $c->{'request'}->{'parameters'}->{'entries'} || $c->stash->{'default_page_size'},
                    page     => $c->{'request'}->{'parameters'}->{'page'} || 1,
                    next     => exists $c->{'request'}->{'parameters'}->{'next'}      || $c->{'request'}->{'parameters'}->{'next.x'},
                    previous => exists $c->{'request'}->{'parameters'}->{'previous'}  || $c->{'request'}->{'parameters'}->{'previous.x'},
                    first    => exists $c->{'request'}->{'parameters'}->{'first'}     || $c->{'request'}->{'parameters'}->{'first.x'},
                    last     => exists $c->{'request'}->{'parameters'}->{'last'}      || $c->{'request'}->{'parameters'}->{'last.x'},
                    pages    => $c->{'request'}->{'parameters'}->{'total_pages'}      || '',
                };
            } else {
                $arg{'pager'} = {};
            }
        }

        # no paging except on html pages
        my $view_mode = $c->{'request'}->{'parameters'}->{'view_mode'} || 'html';
        if($view_mode ne 'html') {
            delete $arg{'pager'};
            delete $c->stash->{'use_pager'};
        }

        if(   $function eq 'get_hosts'
           or $function eq 'get_services'
           ) {
            $arg{'enable_shinken_features'} = $c->stash->{'enable_shinken_features'};
        }

        @{$arg} = %arg;
    }

    # send query to selected backends
    my $get_results_for = [];
    for my $peer ( @{ $self->get_peers() } ) {
        if(defined $backends) {
            unless(defined $backends->{$peer->{'key'}}) {
                #$c->log->debug("skipped peer (undef): ".$peer->{'name'});
                next;
            }
        }
        if($c->stash->{'failed_backends'}->{$peer->{'key'}}) {
            #$c->log->debug("skipped peer (down): ".$peer->{'name'});
            next;
        }
        unless($peer->{'enabled'} == 1) {
            #$c->log->debug("skipped peer (disabled): ".$peer->{'name'});
            next;
        }
        push @{$get_results_for}, $peer->{'key'};
    }
    return($get_results_for, $arg, \%arg);
}


########################################

=head2 _get_result

  _get_result($peers, $function, $args)

run function on several peers and collect result.

=cut

sub _get_result {
    my($self, $peers, $function, $arg, $force_serial) = @_;
    if($ENV{'THRUK_NO_CONNECTION_POOL'}
       or $force_serial
       or scalar @{$peers} <= 1)
    {
        return $self->_get_result_serial($peers, $function, $arg, $ENV{'THRUK_USE_SHADOW'});
    }
    return $self->_get_result_parallel($peers, $function, $arg, $ENV{'THRUK_USE_SHADOW'});
}

########################################

=head2 _get_result_serial

  _get_result_serial($peers, $function, $arguments)

returns result for given function

=cut

sub _get_result_serial {
    my($self,$peers, $function, $arg, $use_shadow) = @_;
    my ($totalsize, $result, $type) = (0);
    my $c  = $Thruk::Backend::Manager::c;
    my $t1 = [gettimeofday];
    $c->stats->profile( begin => "_get_result_serial($function)");

    if($use_shadow and $function =~ m/^get_/mxo and $function ne 'get_logs' and $function ne 'send_command') {
        ($peers, $result, $type, $totalsize) = $self->_get_results_xs_pool($peers, $function, $arg);
    }

    for my $key (@{$peers}) {
        my $peer = $self->get_peer_by_key($key);
        # skip already failed peers for this request
        next if $c->stash->{'failed_backends'}->{$key};

        my @res = Thruk::Backend::Pool::do_on_peer($key, $function, $arg, $use_shadow);
        my $res = shift @res;
        my($typ, $size, $data, $last_error) = @{$res};
        chomp($last_error) if $last_error;
        if(!$last_error and defined $size) {
            $totalsize += $size;
            $type       = $typ;
            $result->{ $key } = $data;
        }
        #&timing_breakpoint('_get_result_serial fetched: '.$key);
        $c->stash->{'failed_backends'}->{$key} = $last_error if $last_error;
        $peer->{'last_error'} = $last_error;
    }

    my $elapsed = tv_interval($t1);
    $c->stash->{'total_backend_waited'} += $elapsed;

    $c->stats->profile( end => "_get_result_serial($function)");
    #&timing_breakpoint('_get_result_serial end: '.$function);
    return($result, $type, $totalsize);
}

########################################

=head2 _get_result_parallel

  _get_result_parallel($peers, $function, $arguments)

returns result for given function and args using the worker pool

=cut

sub _get_result_parallel {
    my($self, $peers, $function, $arg, $use_shadow) = @_;
    my ($totalsize, $result, $type) = (0);
    my $c = $Thruk::Backend::Manager::c;

    $c->stats->profile( begin => "_get_result_parallel(".join(',', @{$peers}).")");

    my @jobs;
    for my $key (@{$peers}) {
        # skip already failed peers for this request
        if(!$c->stash->{'failed_backends'}->{$key}) {
            push @jobs, [$key, $function, $arg, $use_shadow];
        }
    }
    $Thruk::Backend::Pool::pool->add_bulk(\@jobs);

    my $times = {};
    my $results = $Thruk::Backend::Pool::pool->remove_all();
    for my $res (@{$results}) {
        my($key, $time, $typ, $size, $data, $last_error) = @{$res};
        $times->{$key} = $time;
        chomp($last_error) if $last_error;
        my $peer = $self->get_peer_by_key($key);
        $c->stash->{'failed_backends'}->{$key} = $last_error if $last_error;
        $peer->{'last_error'} = $last_error;
        if(!$last_error and defined $size) {
            $totalsize += $size;
            $type       = $typ;
            $result->{$key} = $data;
        }
    }

    my @timessorted = reverse sort { $times->{$a} <=> $times->{$b} } keys(%{$times});
    $c->stash->{'total_backend_waited'} += $times->{$timessorted[0]};
    $c->stats->profile( comment => "slowest site: ".$timessorted[0].' -> '.$times->{$timessorted[0]});

    $c->stats->profile( end => "_get_result_parallel(".join(',', @{$peers}).")");
    return($result, $type, $totalsize);
}


########################################

=head2 _get_results_xs_pool

  _get_results_xs_pool($peers, $function, $arg)

get result from xs thread pool

=cut
sub _get_results_xs_pool {
    my($self, $peers, $function, $arg) = @_;
    my $c               = $Thruk::Backend::Manager::c;

    #&timing_breakpoint('_get_results_xs_pool begin: '.$function);
    $c->stats->profile( begin => "_get_results_xs_pool()");

    my $result;
    my $remaining_peers = [];
    my $totalsize       = 0;
    my $type;

    my @pool_do;
    my @cache_args;
    my $sorted_results = {};
    for my $key (@{$peers}) {
        my $peer = $self->get_peer_by_key($key);
        if(!$peer->{'cacheproxy'}) {
            push @{$remaining_peers}, $key;
            next;
        }

        $sorted_results->{$key} = {
            'keys'   => [],
            'res'    => [],
            'opts'   => [],
            'failed' => 0,
        };
        local $ENV{'THRUK_SELECT'} = 1;
        if(!@cache_args) {
            @cache_args = @{$peer->{'cacheproxy'}->$function(@{$arg})};
            my($statement, $keys, $opt) = @cache_args;
            if(ref $statement ne 'ARRAY') {
                @cache_args = ([$statement, $keys, $opt]);
            }
            for my $tmp (@cache_args) {
                if($tmp->[0] =~ m/^Stats/mxo) {
                    ($tmp->[0],$tmp->[1]) = Monitoring::Livestatus::extract_keys_from_stats_statement($tmp->[0]);
                }
            }
        }

        my $x = 0;
        for my $tmp (@cache_args) {
            push @pool_do, $x;
            push @pool_do, $peer->{'key'};
            push @pool_do, $peer->{'cacheproxy'}->{'live'}->{'peer'};
            my($statement, $keys, $opt) = @{$tmp};
            push @pool_do, $statement;
            $sorted_results->{$key}->{'keys'}->[$x] = $keys;
            $sorted_results->{$key}->{'opts'}->[$x] = $opt;
            $x++;
        }
    }

    # collect pool results
    if(@pool_do) {
        #&timing_breakpoint('_get_results_xs_pool socket_pool_do');
        my $thread_num = scalar @pool_do;
        if($thread_num > 100) { $thread_num = 100; } # limit thread size, tests showed that higher number do not increase performance
        my $raw = Thruk::Utils::XS::socket_pool_do($thread_num, \@pool_do);
        #&timing_breakpoint('_get_results_xs_pool socket_pool_do done');
        my $decoder = JSON::XS->new->utf8->relaxed;
        for my $row (@{$raw}) {
            if($row->{'success'}) {
                $sorted_results->{$row->{'key'}}->{'res'}->[$row->{'num'}] = $decoder->decode(delete $row->{'result'});
            } else {
                $sorted_results->{$row->{'key'}}->{'failed'} = $row->{'result'};
            }
        }
        $raw = undef;
        #&timing_breakpoint('_get_results_xs_pool sorted and decoded');
        my $post_process;
        # iterate over original peers to retain order
        # this keeps identical results in the order of our backends
        for my $peer ( @{ $self->get_peers() } ) {
            my $key = $peer->{'key'};
            my $sorted   = $sorted_results->{$key};
            next if !defined $sorted;
            if($sorted->{'failed'}) {
                $c->stash->{'failed_backends'}->{$key} = $sorted->{'failed'};
                $peer->{'last_error'} = $sorted->{'failed'};
                next;
            }
            my $optimized = 0;
            my $res_size = scalar @{$sorted->{'res'}};
            for(my $x=0; $x<$res_size;$x++) {
                $sorted->{'opts'}->[$x]->{wrapped_json} = 1;
                $sorted->{'res'}->[$x] = $peer->{'cacheproxy'}->{'live'}->{'backend_obj'}->post_processing($sorted->{'res'}->[$x], $sorted->{'opts'}->[$x], $sorted->{'keys'}->[$x]);
                $totalsize += $peer->{'cacheproxy'}->{'live'}->{'backend_obj'}->{'meta_data'}->{'total_count'};
                if($res_size == 1
                   && $sorted->{'keys'}->[$x]
                   && $sorted->{'opts'}->[$x]->{limit}
                   && ref $sorted->{'res'}->[$x]->{'result'} eq 'ARRAY'
                   && $function ne 'get_processinfo'
                ) {
                #if($function eq 'get_services' || $function eq 'get_hosts') {
                    # optimized postprocessing
                    if(!defined $post_process) {
                        $post_process = {
                            'results'  => [],
                            'opts'     => $sorted->{'opts'}->[$x],
                            'keys'     => $sorted->{'keys'}->[$x],
                        };
                        push @{$sorted->{'keys'}->[$x]}, 'peer_key';
                    }
                    # add peer key
                    map { push(@{$_}, $key) } @{$sorted->{'res'}->[$x]->{'result'}};
                    push @{$post_process->{'results'}}, @{$sorted->{'res'}->[$x]->{'result'}};
                    $optimized = 1;
                } else {
                    $sorted->{'opts'}->[$x]->{slice} = 1 if $sorted->{'keys'}->[$x];
                    $sorted->{'res'}->[$x] = Monitoring::Livestatus::selectall_arrayref(undef, "", $sorted->{'opts'}->[$x], undef, $sorted->{'res'}->[$x]);
                }
            }
            if(!$optimized) {
                my @res = $peer->{'cacheproxy'}->$function(data => ($res_size == 1 ? $sorted->{'res'}->[0] : $sorted->{'res'}));
                my($data,$typ,$size) = @res;
                $type                = $typ;
                $result->{$key}      = $data;
            }
        }

        if($post_process) {
            # get sort keys
            my $sortkeys = [];
            for my $sortk (@{$post_process->{'opts'}->{sort}}) {
                my($key, $dir) = split/\s+/mx, $sortk;
                my $x = 0;
                for my $k (@{$post_process->{'keys'}}) {
                    if($k eq $key) {
                        push(@{$sortkeys}, $x, $dir);
                        last;
                    }
                    $x++;
                }
            }
            # sort our arrays
            if((!$type or $type ne 'sorted') and scalar @{$sortkeys} > 0) {
                $post_process->{'results'} = _sort_nr($post_process->{'results'}, $sortkeys);
            }
            # apply limit
            $post_process->{'results'}  = $self->_limit( $post_process->{'results'}, $post_process->{opts}->{'limit'} );
            # splice result, callbacks are missing...
            $post_process->{'results'}  = Monitoring::Livestatus::selectall_arrayref(undef, "", { slice => 1 }, undef, { keys => $post_process->{keys}, result => $post_process->{'results'}});
            $result->{'_all_'} = $post_process->{'results'};
        }
    }

    $c->stats->profile( end => "_get_results_xs_pool()");
    #&timing_breakpoint('_get_results_xs_pool end: '.$function);

    return($remaining_peers, $result, $type, $totalsize);
}

########################################

=head2 _remove_duplicates

  _remove_duplicates($data)

removes duplicate entries from a array of hashes

=cut

sub _remove_duplicates {
    my $self = shift;
    my $data = shift;
    my $c    = $Thruk::Backend::Manager::c;

    $c->stats->profile( begin => "Utils::remove_duplicates()" );

    # calculate md5 sums
    my $uniq = {};
    for my $dat ( @{$data} ) {
        my $peer_key = $dat->{'peer_key'};
        delete $dat->{'peer_key'};
        my $peer_name = $c->stash->{'pi_detail'}->{$peer_key}->{'peer_name'};
        my $peer_addr = $c->stash->{'pi_detail'}->{$peer_key}->{'peer_addr'};
        my $md5       = md5_hex( encode_utf8( join( ';', grep(defined, values %{$dat})) ) );
        if( !defined $uniq->{$md5} ) {
            $dat->{'peer_key'}  = $peer_key;
            $dat->{'peer_name'} = $peer_name;
            $dat->{'peer_addr'} = $peer_addr;

            $uniq->{$md5} = {
                'data'      => $dat,
                'peer_key'  => [$peer_key],
                'peer_name' => [$peer_name],
                'peer_addr' => [$peer_addr],
            };
        }
        else {
            push @{ $uniq->{$md5}->{'peer_key'} },  $peer_key;
            push @{ $uniq->{$md5}->{'peer_name'} }, $peer_name;
            push @{ $uniq->{$md5}->{'peer_addr'} }, $peer_addr;
        }
    }

    my $return = [];
    for my $data ( values %{$uniq} ) {
        $data->{'data'}->{'backend'} = {
            'peer_key'  => $data->{'peer_key'},
            'peer_name' => $data->{'peer_name'},
            'peer_addr' => $data->{'peer_addr'},
        };
        push @{$return}, $data->{'data'};

    }

    $c->stats->profile( end => "Utils::remove_duplicates()" );
    return ($return);
}

########################################

=head2 _page_data

  _page_data($c, $data, [$result_size], [$total_size])

adds paged data set to the template stash.
Data will be available as 'data'
The pager itself as 'pager'

=cut

sub _page_data {
    my $self                = shift;
    my $c                   = shift || $Thruk::Backend::Manager::c;
    my $data                = shift || [];
    return $data unless defined $c;
    my $default_result_size = shift || $c->stash->{'default_page_size'};
    my $totalsize           = shift;

    # set some defaults
    $c->stash->{'pager'} = "";
    $c->stash->{'data'}  = $data;

    # page only in html mode
    my $view_mode = $c->{'request'}->{'parameters'}->{'view_mode'} || 'html';
    return $data unless $view_mode eq 'html';
    my $entries = $c->{'request'}->{'parameters'}->{'entries'} || $default_result_size;
    return $data unless defined $entries;
    $c->stash->{'entries_per_page'} = $entries;

    # we dont use paging at all?
    unless($c->stash->{'use_pager'}) {
        $c->stash->{'pager'} = { 'total_entries' => ($totalsize || scalar @{$data}) };
        return $data;
    }

    my $pager = new Data::Page;
    if(defined $totalsize) {
        $pager->total_entries( $totalsize );
    } else {
        $pager->total_entries( scalar @{$data} );
    }
    if( $entries eq 'all' ) { $entries = $pager->total_entries; }
    my $pages = 0;
    if( $entries > 0 ) {
        $pages = POSIX::ceil( $pager->total_entries / $entries );
    }
    else {
        $c->stash->{'data'} = $data;
        return $data;
    }

    my $page = 1;
    # current page set by get parameter
    if(defined $c->{'request'}->{'parameters'}->{'page'}) {
        $page = $c->{'request'}->{'parameters'}->{'page'};
    }
    # current page set by jump anchor
    elsif(defined $c->{'request'}->{'parameters'}->{'jump'}) {
        my $nr = 0;
        my $jump = $c->{'request'}->{'parameters'}->{'jump'};
        if(exists $data->[0]->{'description'}) {
            for my $row (@{$data}) {
                $nr++;
                if(defined $row->{'host_name'} and defined $row->{'description'} and $row->{'host_name'}."_".$row->{'description'} eq $jump) {
                    $page = POSIX::ceil($nr / $entries);
                    last;
                }
            }
        }
        elsif(exists $data->[0]->{'name'}) {
            for my $row (@{$data}) {
                $nr++;
                if(defined $row->{'name'} and $row->{'name'} eq $jump) {
                    $page = POSIX::ceil($nr / $entries);
                    last;
                }
            }
        }
    }

    # last/first/prev or next button pressed?
    if(   exists $c->{'request'}->{'parameters'}->{'next'}
       or exists $c->{'request'}->{'parameters'}->{'next.x'} ) {
        $page++;
    }
    elsif (   exists $c->{'request'}->{'parameters'}->{'previous'}
           or exists $c->{'request'}->{'parameters'}->{'previous.x'} ) {
        $page-- if $page > 1;
    }
    elsif (    exists $c->{'request'}->{'parameters'}->{'first'}
            or exists $c->{'request'}->{'parameters'}->{'first.x'} ) {
        $page = 1;
    }
    elsif (    exists $c->{'request'}->{'parameters'}->{'last'}
            or exists $c->{'request'}->{'parameters'}->{'last.x'} ) {
        $page = $pages;
    }

    if( $page < 0 )      { $page = 1; }
    if( $page > $pages ) { $page = $pages; }

    $c->stash->{'current_page'} = $page;

    if( $entries eq 'all' ) {
        $c->stash->{'data'} = $data;
    }
    else {
        $pager->entries_per_page($entries);
        $pager->current_page($page);
        my @data = $pager->splice($data);
        $c->stash->{'data'} = \@data;
    }

    $c->stash->{'pager'} = $pager;
    $c->stash->{'pages'} = $pages;

    # set some variables to avoid undef values in templates
    $c->stash->{'pager_previous_page'} = $pager->previous_page() || 0;
    $c->stash->{'pager_next_page'}     = $pager->next_page()     || 0;

    return $data;
}

########################################

=head2 reset_failed_backends

  reset_failed_backends([ $c ])

Reset failed backends cache. Retries
are useless unless reseting this cache
because failed backends won't be asked
twice per request.

=cut

sub reset_failed_backends {
    my $self = shift;
    my $c    = shift || $Thruk::Backend::Manager::c;
    $c->stash->{'failed_backends'} = {};
    return;
}

##########################################################

=head2 AUTOLOAD

  AUTOLOAD()

redirects sub calls to out backends

=cut

sub AUTOLOAD {
    my $self = shift;
    my $name = $AUTOLOAD;
    my $type = ref($self) or confess "$self is not an object, called as (" . $name . ")";
    $name =~ s/.*://mx;    # strip fully-qualified portion
    return $self->_do_on_peers( $name, \@_ );
}

##########################################################

=head2 DESTROY

  DESTROY()

destroy this

=cut

sub DESTROY {
}

##########################################################
sub _merge_answer {
    my($self, $data, $type) = @_;
    my $c      = $Thruk::Backend::Manager::c;
    my $return = [];
    if( defined $type and $type eq 'hash' ) {
        $return = {};
    }

    $c->stats->profile( begin => "_merge_answer()" );

    if(defined $data->{'_all_'}) {
        $return = $data->{_all_};
    }

    # iterate over original peers to retain order
    for my $peer ( @{ $self->get_peers() } ) {
        my $key = $peer->{'key'};
        next if !defined $data->{$key};
        confess("not a hash") unless ref $data eq 'HASH';

        if( ref $data->{$key} eq 'ARRAY' ) {
            $return = [] unless defined $return;
            if(defined $data->{$key}->[0] && ref $data->{$key}->[0] eq 'HASH') {
                map { $_->{'peer_key'} = $key } @{$data->{$key}};
            }
            $return = [ @{$return}, @{$data->{$key}} ];
        }
        elsif ( ref $data->{$key} eq 'HASH' ) {
            $return = {} unless defined $return;
            $return = {} unless ref $return eq 'HASH';
            my $tmp = $data->{$key};
            map { $tmp->{$_}->{'peer_key'} = $key } keys %{$data->{$key}};
            $return = { %{$return}, %{$data->{$key} } };
        }
        else {
            push @{$return}, $data->{$key};
        }
    }

    $c->stats->profile( end => "_merge_answer()" );

    return ($return);
}

##########################################################
# merge hostgroups and merge 'members' of matching groups
sub _merge_hostgroup_answer {
    my($self, $data) = @_;
    my $c      = $Thruk::Backend::Manager::c;
    my $groups = {};

    $c->stats->profile( begin => "_merge_hostgroup_answer()" );

    # iterate over original peers to retain order
    for my $peer ( @{ $self->get_peers() } ) {
        my $key  = $peer->peer_key();
        my $name = $peer->peer_name();
        next if !defined $data->{$key};
        confess("not an array ref") if ref $data->{$key} ne 'ARRAY';

        for my $row ( @{ $data->{$key} } ) {
            if( !defined $groups->{ $row->{'name'} } ) {
                $groups->{ $row->{'name'} } = $row;
                $groups->{ $row->{'name'} }->{'members'} = [ @{ $row->{'members'} } ] if $row->{'members'};
            }
            else {
                $groups->{ $row->{'name'} }->{'members'} = [ @{ $groups->{ $row->{'name'} }->{'members'} }, @{ $row->{'members'} } ] if $row->{'members'};
            }

            if( !defined $groups->{ $row->{'name'} }->{'backends_hash'} ) { $groups->{ $row->{'name'} }->{'backends_hash'} = {} }
            $groups->{ $row->{'name'} }->{'backends_hash'}->{$name} = 1;
        }
    }

    # set backends used
    for my $group ( values %{$groups} ) {
        $group->{'backend'} = [];
        @{ $group->{'backend'} } = sort keys %{ $group->{'backends_hash'} };
        delete $group->{'backends_hash'};
    }
    my @return = values %{$groups};

    $c->stats->profile( end => "_merge_hostgroup_answer()" );

    return ( \@return );
}

##########################################################
# merge servicegroups and merge 'members' of matching groups
sub _merge_servicegroup_answer {
    my($self, $data) = @_;
    my $c      = $Thruk::Backend::Manager::c;
    my $groups = {};

    $c->stats->profile( begin => "_merge_servicegroup_answer()" );

    # iterate over original peers to retain order
    for my $peer ( @{ $self->get_peers() } ) {
        my $key  = $peer->peer_key();
        my $name = $peer->peer_name();
        next if !defined $data->{$key};
        confess("not an array ref") if ref $data->{$key} ne 'ARRAY';

        for my $row ( @{ $data->{$key} } ) {
            if( !defined $groups->{ $row->{'name'} } ) {
                $groups->{ $row->{'name'} } = $row;
                $groups->{ $row->{'name'} }->{'members'} = [ @{ $row->{'members'} } ] if $row->{'members'};
            }
            else {
                $groups->{ $row->{'name'} }->{'members'} = [ @{ $groups->{ $row->{'name'} }->{'members'} }, @{ $row->{'members'} } ] if $row->{'members'};
            }
            if( !defined $groups->{ $row->{'name'} }->{'backends_hash'} ) { $groups->{ $row->{'name'} }->{'backends_hash'} = {} }
            $groups->{$row->{'name'}}->{'backends_hash'}->{$name} = 1;
        }
    }

    # set backends used
    for my $group ( values %{$groups} ) {
        $group->{'backend'} = [];
        @{ $group->{'backend'} } = sort keys %{ $group->{'backends_hash'} };
        delete $group->{'backends_hash'};
    }

    my @return = values %{$groups};

    $c->stats->profile( end => "_merge_servicegroup_answer()" );

    return ( \@return );
}

##########################################################
sub _merge_stats_answer {
    my($self, $data) = @_;
    my $c = $Thruk::Backend::Manager::c;
    my $return;

    $c->stats->profile( begin => "_merge_stats_answer()" );

    my @peers = keys %{$data};
    return if scalar @peers == 0;

    my $first = shift @peers;
    for my $key ( keys %{ $data->{$first} } ) {
        $return->{$key} = $data->{$first}->{$key};
        if( $key =~ m/_sum$/mxo ) {
            for my $peername ( @peers ) { $return->{$key} += $data->{$peername}->{$key}; }
        }
        elsif ( $key =~ m/_min$/mxo ) {
            for my $peername ( @peers ) { $return->{$key} = $data->{$peername}->{$key} if $return->{$key} > $data->{$peername}->{$key}; }
        }
        elsif ( $key =~ m/_max$/mxo ) {
            for my $peername ( @peers ) { $return->{$key} = $data->{$peername}->{$key} if $return->{$key} < $data->{$peername}->{$key}; }
        }
    }

    # percentages and averages?
    for my $key ( keys %{$return} ) {
        if( $key =~ m/^(.*)_(\d+|all)_sum$/mxo ) {
            my $pkey = $1 . '_sum';
            my $nkey = $1 . '_' . $2 . '_perc';
            if( exists $return->{$pkey} and $return->{$pkey} > 0 ) {
                $return->{$nkey} = $return->{$key} / $return->{$pkey} * 100;
            }
            else {
                $return->{$nkey} = 0;
            }
        }

        # active averages
        for my $akey (
            qw/execution_time_sum
            latency_sum
            active_state_change_sum/
            )
        {
            if( $key =~ m/(hosts|services)_$akey/mx ) {
                my $type = $1;
                my $nkey = $type . '_' . $akey;
                $nkey =~ s/_sum$/_avg/mxo;
                $return->{$nkey} = 0;
                if( $return->{$key} > 0 and $return->{ $type . '_active_sum' } > 0 ) {
                    $return->{$nkey} = $return->{$key} / $return->{ $type . '_active_sum' };
                }
            }
        }

        # passive averages
        for my $akey (qw/passive_state_change_sum/) {
            if( $key =~ m/(hosts|services)_$akey/mx ) {
                my $type = $1;
                my $nkey = $type . '_' . $akey;
                $nkey =~ s/_sum$/_avg/mxo;
                $return->{$nkey} = 0;
                if( $return->{$key} > 0 ) {
                    $return->{$nkey} = $return->{$key} / $return->{ $type . '_passive_sum' };
                }
            }
        }
    }

    $c->stats->profile( end => "_merge_stats_answer()" );

    return $return;
}

##########################################################
sub _sum_answer {
    my($self, $data) = @_;
    #my $c    = $Thruk::Backend::Manager::c;
    my $return;

    #$c->stats->profile( begin => "_sum_answer()" );

    my @peers = keys %{$data};
    return if scalar @peers == 0;

    my $first = shift @peers;
    for my $key ( keys %{ $data->{$first} } ) {
        $return->{$key} = $data->{$first}->{$key};

        if($key eq 'peer_key') {
            $return->{$key} .= ','.join(',', @peers);
        }
        elsif ( looks_like_number( $data->{$first}->{$key} ) ) {
            for my $peername ( @peers ) { $return->{$key} += $data->{$peername}->{$key}; }
        }
    }

    #$c->stats->profile( end => "_sum_answer()" );

    return $return;
}

########################################

=head2 _sort

  _sort($data, $sortby)

sort a array of hashes by hash keys

  sortby can be a scalar

  $sortby = 'name'

  sortby can be an array

  $sortby = [ 'name', 'description' ]

  sortby can be an hash

  $sortby = { 'DESC' => [ 'name', 'description' ] }

=cut

sub _sort {
    my($self, $data, $sortby) = @_;
    my $c = $Thruk::Backend::Manager::c;
    my( @sorted, $key, $order );

    $c->stats->profile( begin => "_sort()" ) if $c;

    $key = $sortby;
    if( ref $sortby eq 'HASH' ) {
        if(defined $sortby->{'ASC'} and defined $sortby->{'DESC'}) {
            confess('unusual sort config:\n'.Dumper($sortby));
        }
        for my $ord (qw/ASC DESC/) {
            if( defined $sortby->{$ord} ) {
                $key   = $sortby->{$ord};
                $order = $ord;
                last;
            }
        }
    }

    if( !defined $key ) { confess('missing options in sort()'); }

    $order = "ASC" if !defined $order;

    if(ref $data ne 'ARRAY') { confess("Not an ARRAY reference: ".Dumper($data)); }
    if(!defined $data or scalar @{$data} == 0) {
        $c->stats->profile( end => "_sort()" ) if $c;
        return \@sorted
    }

    my @keys;
    if( ref($key) eq 'ARRAY' ) {
        @keys = @{$key};
    }
    else {
        @keys = ($key);
    }

    my @compares;
    for my $key (@keys) {

        # sort numeric
        if( defined $data->[0]->{$key} and $data->[0]->{$key} =~ m/^[\d\.\-]+$/xm ) {
            push @compares, '$a->{"'.$key.'"} <=> $b->{"'.$key.'"}';
        }

        # sort alphanumeric
        else {
            push @compares, '$a->{"'.$key.'"} cmp $b->{"'.$key.'"}';
        }
    }
    my $sortstring = join( ' || ', @compares );

    ## no critic
    no warnings;    # sorting by undef values generates lots of errors
    if( uc $order eq 'ASC' ) {
        eval '@sorted = sort {'.$sortstring.'} @{$data};';
    }
    else {
        eval '@sorted = reverse sort {'.$sortstring.'} @{$data};';
    }
    use warnings;
    ## use critic

    if(scalar @sorted == 0 && $@) {
        confess($@);
    }

    $c->stats->profile( end => "_sort()" ) if $c;

    return ( \@sorted );
}

########################################

=head2 _sort_nr

  _sort_nr($data, $sortby)

sort a array of array by array nr

  sortby must be an array

  [<nr>, <direction>]

  ex.:

  [5, 'asc']
  [5, 'asc', 13, 'desc']

=cut

sub _sort_nr {
    my($data, $sortby) = @_;

    if(ref $data ne 'ARRAY') { confess("Not an ARRAY reference: ".Dumper($data)); }
    if(scalar @{$data} == 0) {
        return([]);
    }

    my @compares;
    while(@{$sortby}) {
        my $nr  = shift @{$sortby};
        my $dir = shift @{$sortby};

        # sort numeric
        if( defined $data->[0]->[$nr] and $data->[0]->[$nr] =~ m/^[\d\.\-]+$/xm ) {
            if(lc $dir eq 'asc') {
                push @compares, '$a->["'.$nr.'"] <=> $b->["'.$nr.'"]';
            } else {
                push @compares, '$b->["'.$nr.'"] <=> $a->["'.$nr.'"]';
            }
        }

        # sort alphanumeric
        else {
            if(lc $dir eq 'asc') {
                push @compares, '$a->["'.$nr.'"] cmp $b->["'.$nr.'"]';
            } else {
                push @compares, '$b->["'.$nr.'"] cmp $a->["'.$nr.'"]';
            }
        }
    }
    my $sortstring = join( ' || ', @compares );

    my @sorted;
    ## no critic
    no warnings;    # sorting by undef values generates lots of errors
    eval '@sorted = sort {'.$sortstring.'} @{$data};';
    use warnings;
    ## use critic

    if(scalar @sorted == 0 && $@) {
        confess(Dumper($sortstring, $sortby, $@));
    }

    return(\@sorted);
}

########################################

=head2 _limit

  _limit($data, $limit)

returns data limited by limit

=cut

sub _limit {
    my($self, $data, $limit) = @_;

    return $data unless defined $limit and $limit > 0;

    if( scalar @{$data} > $limit ) {
        @{$data} = @{$data}[ 0 .. $limit ];
        return $data;
    }

    return ($data);
}


########################################

=head2 _set_user_macros

  _set_user_macros($peer_key)

sets the USER1-256 macros from a resource file. Shinken supports all kind of
macros in resource file, so just replace everything from the resource file.

=cut

sub _set_user_macros {
    my($self, $peer_key, $macros, $file) = @_;
    my $c = $Thruk::Backend::Manager::c;

    my $res;
    if(defined $file) {
        $res = Thruk::Utils::read_resource_file($file);
    }
    if(!defined $res and defined $peer_key) {
        my $backend = $self->get_peer_by_key($peer_key);
        if(defined $backend->{'resource_file'}) {
            $res = Thruk::Utils::read_resource_file($backend->{'resource_file'});
        }
    }
    unless(defined $res) {
        $res = Thruk::Utils::read_resource_file($c->config->{'resource_file'});
    }

    if(defined $res) {
        for my $key (keys %{$res}) {
            $macros->{$key} = $res->{$key};
        }
    }

    return $macros;
}


########################################

=head2 _set_result_defaults

  _set_result_defaults()

set defaults for some results

=cut

sub _set_result_defaults {
    my($self, $function, $data) = @_;

    # set some defaults if no backends where selected
    if($function eq "get_performance_stats" and ref $data eq 'ARRAY') {
        $data = {};
        for my $type (qw{hosts services}) {
            for my $key (qw{_active_sum _active_1_sum _active_5_sum _active_15_sum _active_60_sum _active_all_sum
                            _active_1_perc _active_5_perc _active_15_perc _active_60_perc _active_all_perc
                            _passive_sum _passive_1_sum _passive_5_sum _passive_15_sum _passive_60_sum _passive_all_sum
                            _passive_1_perc _passive_5_perc _passive_15_perc _passive_60_perc _passive_all_perc
                            _execution_time_sum _latency_sum _active_state_change_sum _execution_time_min _latency_min _active_state_change_min _execution_time_max _latency_max
                            _active_state_change_max _passive_state_change_sum _passive_state_change_min _passive_state_change_max
                            _execution_time_avg _latency_avg _active_state_change_avg _passive_state_change_avg
                        }) {
                $data->{$type.$key} = 0;
            }
        }
    }
    elsif($function eq "get_service_stats" and ref $data eq 'ARRAY') {
        $data = {};
        for my $key (qw{
                        total total_active total_passive pending pending_and_disabled pending_and_scheduled ok ok_and_disabled ok_and_scheduled
                        warning warning_and_disabled warning_and_scheduled warning_and_ack warning_on_down_host warning_and_unhandled critical
                        critical_and_disabled critical_and_scheduled critical_and_ack critical_on_down_host critical_and_unhandled
                        unknown unknown_and_disabled unknown_and_scheduled unknown_and_ack unknown_on_down_host unknown_and_unhandled
                        flapping flapping_disabled notifications_disabled eventhandler_disabled active_checks_disabled passive_checks_disabled
                        critical_and_disabled_active critical_and_disabled_passive warning_and_disabled_active warning_and_disabled_passive
                        unknown_and_disabled_active unknown_and_disabled_passive ok_and_disabled_active ok_and_disabled_passive
                        active_checks_disabled_active active_checks_disabled_passive
                     }) {
            $data->{$key} = 0;
        }
    }
    elsif($function eq "get_host_stats" and ref $data eq 'ARRAY') {
        $data = {};
        for my $key (qw{
                        total total_active total_passive pending pending_and_disabled pending_and_scheduled up up_and_disabled up_and_scheduled
                        down down_and_ack down_and_scheduled down_and_disabled down_and_unhandled unreachable unreachable_and_ack unreachable_and_scheduled
                        unreachable_and_disabled unreachable_and_unhandled flapping flapping_disabled notifications_disabled eventhandler_disabled active_checks_disabled passive_checks_disabled outages
                        down_and_disabled_active down_and_disabled_passive unreachable_and_disabled_active unreachable_and_disabled_passive up_and_disabled_active
                        up_and_disabled_passive active_checks_disabled_active active_checks_disabled_passive
                     }) {
            $data->{$key} = 0;
        }
    }
    elsif($function eq "get_extra_perf_stats" and ref $data eq 'ARRAY') {
        $data = {};
        for my $key (qw{
                        cached_log_messages connections connections_rate host_checks
                        host_checks_rate requests requests_rate service_checks
                        service_checks_rate neb_callbacks neb_callbacks_rate
                     }) {
            $data->{$key} = 0;
        }
    }
    return $data;
}

########################################

=head1 AUTHOR

Sven Nierlein, 2009-2014, <sven@nierlein.org>

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
