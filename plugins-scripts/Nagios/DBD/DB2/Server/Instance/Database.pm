package DBD::DB2::Server::Instance::Database;

use strict;

our @ISA = qw(DBD::DB2::Server::Instance);

{
  my @databases = ();
  my $initerrors = undef;

  sub add_database {
    push(@databases, shift);
  }

  sub return_databases {
    return reverse
        sort { $a->{name} cmp $b->{name} } @databases;
  }

  sub init_databases {
    my %params = @_;
    my $num_databases = 0;
    if ($params{mode} =~ /server::instance::listdatabases/) {
      my %thisparams = %params;
      $thisparams{name} = $params{database};
      my $database = DBD::DB2::Server::Instance::Database->new(
          %thisparams);
      add_database($database);
      $num_databases++;
    } elsif (($params{mode} =~ /server::instance::database::listtablespace/) ||
        ($params{mode} =~ /server::instance::database::tablespace/) ||
        ($params{mode} =~ /server::instance::database::bufferpool/)) {
      my %thisparams = %params;
      $thisparams{name} = $params{database};
      my $database = DBD::DB2::Server::Instance::Database->new(
          %thisparams);
      add_database($database);
      $num_databases++;
    } elsif ($params{mode} =~ /server::instance::database::lock/) {
      my %thisparams = %params;
      $thisparams{name} = $params{database};
      my $database = DBD::DB2::Server::Instance::Database->new(
          %thisparams);
      add_database($database);
      $num_databases++;
    } elsif (($params{mode} =~ /server::instance::database::usage/)) {
      my @databaseresult = $params{handle}->fetchrow_array(q{
        CALL GET_DBSIZE_INFO(?, ?, ?, 0)
      });
      my ($snapshot_timestamp, $db_size, $db_capacity)  = 
          $params{handle}->fetchrow_array(q{
              SELECT * FROM SYSTOOLS.STMG_DBSIZE_INFO
          });
      if ($snapshot_timestamp) {
        my %thisparams = %params;
        $thisparams{name} = $params{database};
        $thisparams{snapshot_timestamp} = $snapshot_timestamp;
        $thisparams{db_size} = $db_size;
        $thisparams{db_capacity} = $db_capacity;
        my $database = DBD::DB2::Server::Instance::Database->new(
            %thisparams);
        add_database($database);
        $num_databases++;
      } else {
        $initerrors = 1;
        return undef;
      }
    } else {
      my %thisparams = %params;
      $thisparams{name} = $params{database};
      my $database = DBD::DB2::Server::Instance::Database->new(
          %thisparams);
      add_database($database);
      $num_databases++;
    }
  }

}

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    handle => $params{handle},
    name => $params{name},
    warningrange => $params{warningrange},
    criticalrange => $params{criticalrange},
    tablespaces => [],
    bufferpools => [],
    partitions => [],
    locks => [],
    snapshot_timestamp => $params{snapshot_timestamp},
    db_size => $params{db_size},
    db_capacity => $params{db_capacity},
    log_utilization => undef,
    srp => undef,
    awp => undef,
    rows_read => undef,
  };
  bless $self, $class;
  $self->init(%params);
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  $self->init_nagios();
  if (($params{mode} =~ /server::instance::database::listtablespaces/) ||
      ($params{mode} =~ /server::instance::database::tablespace/)) {
    DBD::DB2::Server::Instance::Database::Tablespace::init_tablespaces(%params);
    if (my @tablespaces = 
        DBD::DB2::Server::Instance::Database::Tablespace::return_tablespaces()) {
      $self->{tablespaces} = \@tablespaces;
    } else {
      $self->add_nagios_critical("unable to aquire tablespace info");
    }
  } elsif (($params{mode} =~ /server::instance::database::listbufferpools/) ||
      ($params{mode} =~ /server::instance::database::bufferpool/)) {
    DBD::DB2::Server::Instance::Database::Bufferpool::init_bufferpools(%params);
    if (my @bufferpools = 
        DBD::DB2::Server::Instance::Database::Bufferpool::return_bufferpools()) {
      $self->{bufferpools} = \@bufferpools;
    } else {
      $self->add_nagios_critical("unable to aquire bufferpool info");
    }
  } elsif ($params{mode} =~ /server::instance::database::lock/) {
    DBD::DB2::Server::Instance::Database::Lock::init_locks(%params);
    if (my @locks = 
        DBD::DB2::Server::Instance::Database::Lock::return_locks()) {
      $self->{locks} = \@locks;
    } else {
      $self->add_nagios_critical("unable to aquire lock info");
    }
  } elsif ($params{mode} =~ /server::instance::database::usage/) {
    # http://publib.boulder.ibm.com/infocenter/db2luw/v9/topic/com.ibm.db2.udb.admin.doc/doc/r0011863.htm
    $self->{db_usage} = ($self->{db_size} * 100 / $self->{db_capacity});
  } elsif ($params{mode} =~ /server::instance::database::logutilization/) {
    DBD::DB2::Server::Instance::Database::Partition::init_partitions(%params);
    if (my @partitions = 
        DBD::DB2::Server::Instance::Database::Partition::return_partitions()) {
      $self->{partitions} = \@partitions;
    } else {
      $self->add_nagios_critical("unable to aquire partitions info");
    }
  } elsif ($params{mode} =~ /server::instance::database::srp/) {
    # http://www.dbisoftware.com/blog/db2_performance.php?id=96
    $self->{srp} = $params{handle}->fetchrow_array(q{
        SELECT 
          100 - (((pool_async_data_reads + pool_async_index_reads) * 100 ) /
          (pool_data_p_reads + pool_index_p_reads + 1)) 
        AS
          srp 
        FROM
          sysibmadm.snapdb 
        WHERE 
          db_name = ?
    }, $self->{name});
    if (! defined $self->{srp}) {
      $self->add_nagios_critical("unable to aquire srp info");
    }
  } elsif ($params{mode} =~ /server::instance::database::awp/) {
    # http://www.dbisoftware.com/blog/db2_performance.php?id=117
    $self->{awp} = $params{handle}->fetchrow_array(q{
        SELECT 
          (((pool_async_data_writes + pool_async_index_writes) * 100 ) /
          (pool_data_writes + pool_index_writes + 1)) 
        AS
          awp 
        FROM
          sysibmadm.snapdb 
        WHERE 
          db_name = ?
    }, $self->{name});
    if (! defined $self->{awp}) {
      $self->add_nagios_critical("unable to aquire awp info");
    }
  } elsif ($params{mode} =~ /server::instance::database::indexusage/) {
    ($self->{rows_read}, $self->{rows_selected}) = $params{handle}->fetchrow_array(q{
        SELECT
            rows_read, rows_selected
        FROM
            sysibmadm.snapdb
    });
    if (! defined $self->{rows_read}) {
      $self->add_nagios_critical("unable to aquire rows info");
    } else {
      $self->{index_usage} = $self->{rows_read} ? 
          ($self->{rows_selected} / $self->{rows_read} * 100) : 100;
    }
  } elsif ($params{mode} =~ /server::instance::database::connectedusers/) {
    $self->{connected_users} = $self->{handle}->fetchrow_array(q{
        SELECT COUNT(*) FROM sysibmadm.applications WHERE appl_status = 'CONNECTED'
    });
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /server::instance::database::listtablespaces/) {
      foreach (sort { $a->{name} cmp $b->{name}; }  @{$self->{tablespaces}}) {
	printf "%s\n", $_->{name};
      }
      $self->add_nagios_ok("have fun");
    } elsif ($params{mode} =~ /server::instance::database::tablespace/) {
      foreach (@{$self->{tablespaces}}) {
        # sind hier noch nach pctused sortiert
        $_->nagios(%params);
        $self->merge_nagios($_);
      }
    } elsif ($params{mode} =~ /server::instance::database::listbufferpools/) {
      foreach (sort { $a->{name} cmp $b->{name}; }  @{$self->{bufferpools}}) {
        printf "%s\n", $_->{name};
      }
      $self->add_nagios_ok("have fun");
    } elsif ($params{mode} =~ /server::instance::database::bufferpool/) {
      foreach (@{$self->{bufferpools}}) {
        $_->nagios(%params);
        $self->merge_nagios($_);
      }
    } elsif ($params{mode} =~ /server::instance::database::lock/) {
      foreach (@{$self->{locks}}) {
        $_->nagios(%params);
        $self->merge_nagios($_);
      }
    } elsif ($params{mode} =~ /server::instance::database::logutilization/) {
      foreach (@{$self->{partitions}}) {
        $_->nagios(%params);
        $self->merge_nagios($_);
      }
    } elsif ($params{mode} =~ /server::instance::database::usage/) {
      $self->add_nagios(
          $self->check_thresholds($self->{db_usage}, 80, 90),
          sprintf "database usage is %.2f%%",
              $self->{db_usage});
      $self->add_perfdata(sprintf "\'db_%s_usage\'=%.2f%%;%s;%s",
          lc $self->{name},
          $self->{db_usage},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::database::connectedusers/) {
      $self->add_nagios(
          $self->check_thresholds($self->{connected_users}, 50, 100),
          sprintf "%d connected users",
              $self->{connected_users});
      $self->add_perfdata(sprintf "connected_users=%d;%d;%d",
          $self->{connected_users},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::database::srp/) {
      $self->add_nagios(
          $self->check_thresholds($self->{srp}, '90:', '80:'),       
          sprintf "synchronous read percentage is %.2f%%", $self->{srp});
      $self->add_perfdata(sprintf "srp=%.2f%%;%s;%s",
          $self->{srp},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::database::awp/) {
      $self->add_nagios(
          $self->check_thresholds($self->{awp}, '90:', '80:'),       
          sprintf "asynchronous write percentage is %.2f%%", $self->{awp});
      $self->add_perfdata(sprintf "awp=%.2f%%;%s;%s",
          $self->{awp},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::database::indexusage/) {
      $self->add_nagios(
          $self->check_thresholds($self->{index_usage}, '98:', '90:'),       
          sprintf "index usage is %.2f%%", $self->{index_usage});
      $self->add_perfdata(sprintf "index_usage=%.2f%%;%s;%s",
          $self->{index_usage},
          $self->{warningrange}, $self->{criticalrange});
    }
  }
}


1;
