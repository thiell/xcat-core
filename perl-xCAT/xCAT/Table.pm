# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
#TODO:
#MEMLEAK fix
# see NodeRange.pm for notes about how to produce a memory leak
# xCAT as it stands at this moment shouldn't leak anymore due to what is 
# described there, but that only hides from the real problem and the leak will
# likely crop up if future architecture changes happen
# in summary, a created Table object without benefit of db worker thread
# to abstract its existance will consume a few kilobytes of memory
# that never gets reused
# just enough notes to remind me of the design that I think would allow for
#   -cache to persist so long as '_build_cache' calls concurrently stack (for NodeRange interpretation mainly) (done)
#   -Allow plugins to define a staleness threshold for getNodesAttribs freshness (complicated enough to postpone...)
#    so that actions requested by disparate managed nodes may aggregate in SQL calls
# reference count managed cache lifetime, if clear_cache is called, and build_chache has been called twice, decrement the counter
# if called again, decrement again and clear cache
# for getNodesAttribs, we can put a parameter to request allowable staleneess
# if the cachestamp is too old, build_cache is called
# in this mode, 'use_cache' is temporarily set to 1, regardless of 
# potential other consumers (notably, NodeRange)
#perl errors/and warnings are not currently wrapped.
#  This probably will be cleaned
#up
#Some known weird behaviors
#creating new sqlite db files when only requested to read non-existant table, easy to fix,
#class xcattable
package xCAT::Table;
use xCAT::MsgUtils;
use Sys::Syslog;
use Storable qw/freeze thaw/;
use IO::Socket;
use Data::Dumper;
BEGIN
{
    $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : -d '/opt/xcat' ? '/opt/xcat' : '/usr';
}

# if AIX - make sure we include perl 5.8.2 in INC path.
#       Needed to find perl dependencies shipped in deps tarball.
if ($^O =~ /^aix/i) {
        use lib "/usr/opt/perl5/lib/5.8.2/aix-thread-multi";
        use lib "/usr/opt/perl5/lib/5.8.2";
        use lib "/usr/opt/perl5/lib/site_perl/5.8.2/aix-thread-multi";
        use lib "/usr/opt/perl5/lib/site_perl/5.8.2";
}

use lib "$::XCATROOT/lib/perl";
my $cachethreshold=16; #How many nodes in 'getNodesAttribs' before switching to full DB retrieval

use DBI;

use strict;
use Scalar::Util qw/weaken/;
require xCAT::Schema;
require xCAT::NodeRange;
use Text::Balanced qw(extract_bracketed);
require xCAT::NotifHandler;

my $dbworkerpid; #The process id of the database worker
my $dbworkersocket;
my $dbsockpath = "/tmp/xcat/dbworker.sock";
my $exitdbthread;
my $dbobjsforhandle;


sub dbc_call {
    my $self = shift;
    my $function = shift;
    my @args = @_;
    my $request = { 
         function => $function,
         tablename => $self->{tabname},
         autocommit => $self->{autocommit},
          args=>\@args,
    };
    return dbc_submit($request);
}

sub dbc_submit {
    my $request = shift;
    $request->{'wantarray'} = wantarray();
    my $data = freeze($request);
    $data.= "\nENDOFFREEZEQFVyo4Cj6Q0v\n";
    my $clisock = IO::Socket::UNIX->new(Peer => $dbsockpath, Type => SOCK_STREAM, Timeout => 120 );
    unless ($clisock) {
        use Carp qw/cluck/;
        cluck();
    }
    print $clisock $data;
    $data="";
    my $lastline="";
    while ($lastline ne "ENDOFFREEZEQFVyo4Cj6Q0j\n") { #index($lastline,"ENDOFFREEZEQFVyo4Cj6Q0j") < 0) {
        $lastline = <$clisock>;
	$data .= $lastline;
    }
    my @returndata = @{thaw($data)};
    if (wantarray) {
        return @returndata;
    } else {
        return $returndata[0];
    }
}

sub shut_dbworker {
    $dbworkerpid = 0; #For now, just turn off usage of the db worker
    #This was created as the monitoring framework shutdown code otherwise seems to have a race condition
    #this may incur an extra db handle per service node to tolerate shutdown scenarios
}
sub init_dbworker {
#create a db worker process
    $dbworkerpid = fork;

    unless (defined $dbworkerpid) {
        die "Error spawining database worker";
    }
    unless ($dbworkerpid) {
        #This process is the database worker, it's job is to manage database queries to reduce required handles and to permit cross-process caching
        $0 = "xcatd: DB Access";
        use File::Path;
        mkpath('/tmp/xcat/');
        use IO::Socket;
        $SIG{TERM} = $SIG{INT} = sub {
            $exitdbthread=1;
            $SIG{ALRM} = sub { exit 0; };
            alarm(10);
        };
        unlink($dbsockpath);
        umask(0077);
        $dbworkersocket = IO::Socket::UNIX->new(Local => $dbsockpath, Type => SOCK_STREAM, Listen => 8192);
        unless ($dbworkersocket) {
            die $!;
        }
        my $currcon;
        my $clientset = new IO::Select;
        $clientset->add($dbworkersocket);
        while (not $exitdbthread) {
            eval {
                my @ready_socks = $clientset->can_read;
                foreach $currcon (@ready_socks) {
                    if ($currcon == $dbworkersocket) { #We have a new connection to register
                        my $dbconn = $currcon->accept;
                        if ($dbconn) {
                            $clientset->add($dbconn);
                        }
                    } else {
                        handle_dbc_conn($currcon,$clientset);
                    }
                }
            };
            if ($@) { 
                xCAT::MsgUtils->message("S","xcatd: possible BUG encountered by xCAT DB worker ".$@);
            }
        }
        close($dbworkersocket);
        unlink($dbsockpath);
        exit 0;
    }
    return $dbworkerpid;
}
sub handle_dbc_conn {
    my $client = shift;
    my $clientset = shift;
    my $data;
    if ($data = <$client>) {
	my $lastline;
        while ($lastline ne "ENDOFFREEZEQFVyo4Cj6Q0v\n") { #$data !~ /ENDOFFREEZEQFVyo4Cj6Q0v/) {
	    $lastline = <$client>;
            $data .= $lastline;
        }
        my $request = thaw($data);
        my $response;
        my @returndata;
        if ($request->{'wantarray'}) {
            @returndata = handle_dbc_request($request);
        } else {
            @returndata = (scalar(handle_dbc_request($request)));
        }
        $response = freeze(\@returndata);
        $response .= "\nENDOFFREEZEQFVyo4Cj6Q0j\n";
        print $client $response;
    } else { #Connection terminated, clean up
        $clientset->remove($client);
        close($client);
    }

}

my %opentables; #USED ONLY BY THE DB WORKER TO TRACK OPEN DATABASES
sub handle_dbc_request {
    my $request = shift;
    my $functionname = $request->{function};
    my $tablename = $request->{tablename};
    my @args = @{$request->{args}};
    my $autocommit = $request->{autocommit};
    my $dbindex;
    foreach $dbindex (keys %{$::XCAT_DBHS}) {
        unless ($::XCAT_DBHS->{$dbindex}) { next; }
        unless ($::XCAT_DBHS->{$dbindex} and $::XCAT_DBHS->{$dbindex}->ping) {
            my @afflictedobjs = @{$dbobjsforhandle->{$::XCAT_DBHS->{$dbindex}}};
            my $oldhandle = $::XCAT_DBHS->{$dbindex};
            $::XCAT_DBHS->{$dbindex} = $::XCAT_DBHS->{$dbindex}->clone();
            foreach (@afflictedobjs) { 
                $$_->{dbh} = $::XCAT_DBHS->{$dbindex};
            }   
            $oldhandle->disconnect();
        }   
    }   
    if ($functionname eq 'new') {
        unless ($opentables{$tablename}->{$autocommit}) {
            shift @args; #Strip repeat class stuff
            $opentables{$tablename}->{$autocommit} = xCAT::Table->new(@args);
        }
        if ($opentables{$tablename}->{$autocommit}) {
            return 1;
        } else {
            return 0;
        }
    } else { 
        unless (defined $opentables{$tablename}->{$autocommit}) {
        #We are servicing a Table object that used to be 
        #non data-worker.  Create a new DB worker side Table like the one
        #that requests this
            $opentables{$tablename}->{$autocommit} = xCAT::Table->new($tablename,-create=>0,-autocommit=>$autocommit);
            unless ($opentables{$tablename}->{$autocommit}) {
                return undef;
            }
        }
    }
    if ($functionname eq 'getAllAttribs') {
         return $opentables{$tablename}->{$autocommit}->getAllAttribs(@args);
    } elsif ($functionname eq 'getAttribs') {
         return $opentables{$tablename}->{$autocommit}->getAttribs(@args);
    } elsif ($functionname eq 'getTable') {
         return $opentables{$tablename}->{$autocommit}->getTable(@args);
    } elsif ($functionname eq 'getAllNodeAttribs') {
         return $opentables{$tablename}->{$autocommit}->getAllNodeAttribs(@args);
    } elsif ($functionname eq 'getAllEntries') {
         return $opentables{$tablename}->{$autocommit}->getAllEntries(@args);
    } elsif ($functionname eq 'getAllAttribsWhere') {
         return $opentables{$tablename}->{$autocommit}->getAllAttribsWhere(@args);
    } elsif ($functionname eq 'addAttribs') {
         return $opentables{$tablename}->{$autocommit}->addAttribs(@args);
    } elsif ($functionname eq 'setAttribs') {
         return $opentables{$tablename}->{$autocommit}->setAttribs(@args);
    } elsif ($functionname eq 'setAttribsWhere') {
         return $opentables{$tablename}->{$autocommit}->setAttribsWhere(@args);
    } elsif ($functionname eq 'delEntries') {
         return $opentables{$tablename}->{$autocommit}->delEntries(@args);
    } elsif ($functionname eq 'commit') {
         return $opentables{$tablename}->{$autocommit}->commit(@args);
    } elsif ($functionname eq 'rollback') {
         return $opentables{$tablename}->{$autocommit}->rollback(@args);
    } elsif ($functionname eq 'getNodesAttribs') {
         return $opentables{$tablename}->{$autocommit}->getNodesAttribs(@args);
    } elsif ($functionname eq 'getNodeAttribs') {
         return $opentables{$tablename}->{$autocommit}->getNodeAttribs(@args);
    } elsif ($functionname eq '_set_use_cache') {
         return $opentables{$tablename}->{$autocommit}->_set_use_cache(@args);
    } elsif ($functionname eq '_build_cache') {
         return $opentables{$tablename}->{$autocommit}->_build_cache(@args);
    } elsif ($functionname eq '_clear_cache') {
         return $opentables{$tablename}->{$autocommit}->_clear_cache(@args);
    } else {
        die "undefined function $functionname";
    }
}

sub _set_use_cache {
    my $self = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'_set_use_cache',@_);
    }
    $self->{_use_cache} = shift;
}
#--------------------------------------------------------------------------------

=head1 xCAT::Table

xCAT::Table - Perl module for xCAT configuration access

=head2 SYNOPSIS

use xCAT::Table;
my $table = xCAT::Table->new("tablename");

my $hashref=$table->getNodeAttribs("nodename","columname1","columname2");
printf $hashref->{columname1};


=head2 DESCRIPTION

This module provides convenience methods that abstract the backend specific configuration to a common API.

Currently implements the preferred SQLite backend, as well as a CSV backend, postgresql and MySQL, using their respective perl DBD modules.

NOTES

The CSV backend is really slow at scale.  Room for optimization is likely, but in general DBD::CSV is slow, relative to xCAT 1.2.x.
The SQLite backend, on the other hand, is significantly faster on reads than the xCAT 1.2.x way, so it is recommended.

BUGS

This module is not thread-safe, due to underlying DBD thread issues.  Specifically in testing, SQLite DBD leaks scalars if a thread
where a Table object exists spawns a child and that child exits.  The recommended workaround for now is to spawn a thread to contain
all Table objects if you intend to spawn threads from your main thread.  As long as no thread in which the new method is called spawns
child threads, it seems to work fine.

AUTHOR

Jarrod Johnson <jbjohnso@us.ibm.com>

xCAT::Table is released under an IBM license....


=cut

#--------------------------------------------------------------------------

=head2   Subroutines

=cut

#--------------------------------------------------------------------------

=head3   buildcreatestmt

    Description:  Build create table statement ( see new)

    Arguments:
                Table name
				Table schema ( hash of column names)
    Returns:
                Table creation SQL
    Globals:

    Error:

    Example:

                my $str =
                  buildcreatestmt($self->{tabname},
                                  $xCAT::Schema::tabspec{$self->{tabname}});

=cut

#--------------------------------------------------------------------------------
sub buildcreatestmt
{
    my $tabn  = shift;
    my $descr = shift;
    my $xcatcfg = shift;
    my $retv  = "CREATE TABLE $tabn (\n  ";
    my $col;
    my $types=$descr->{types};

    foreach $col (@{$descr->{cols}})
    {
        my $datatype=get_datatype_string($col,$xcatcfg, $types);
        if ($datatype eq "TEXT") {
	    if (isAKey(\@{$descr->{keys}}, $col)) {   # keys need defined length
		$datatype = "VARCHAR(128)";
	    }
	}
        $retv .= "\"$col\" $datatype ";

        if (grep /^$col$/, @{$descr->{required}})
        {
            $retv .= " NOT NULL";
        }
        $retv .= ",\n  ";
    }
    if ($retv =~ /PRIMARY KEY/) {
	$retv =~ s/,\n  $/\n)/;
    } else {
	$retv .= "PRIMARY KEY (";
	foreach (@{$descr->{keys}})
	{
	    $retv .= "\"$_\","
	}
	$retv =~ s/,$/)\n)/;
    }
	#print "retv=$retv\n";
    return $retv; 
}

sub get_datatype_string {
    my $col=shift;    #column name
    my $xcatcfg=shift;  #db config string
    my $types=shift;  #hash pointer
    my $ret;

    if (($types) && ($types->{$col})) {
	if ($types->{$col} =~ /INTEGER AUTO_INCREMENT/) {
	    if ($xcatcfg =~ /^SQLite:/) {
		$ret = "INTEGER PRIMARY KEY AUTOINCREMENT";
	    } elsif ($xcatcfg =~ /^Pg:/) {
		$ret = "SERIAL";
	    } elsif ($xcatcfg =~ /^mysql:/){
		$ret = "INTEGER AUTO_INCREMENT";
	    } elsif ($xcatcfg =~ /^db2:/){
		$ret = "INTEGER GENERATED ALWAYS AS IDENTITY";  #have not tested on DB2
	    } else {
	    }
	} else {
	    $ret = $types->{$col};
	}
    } else {
	$ret = "TEXT";
    }
    return $ret;
}


sub get_xcatcfg
{
    my $xcatcfg = (defined $ENV{'XCATCFG'} ? $ENV{'XCATCFG'} : '');
    unless ($xcatcfg) {
        if (-r "/etc/xcat/cfgloc") {
	    my $cfgl;
	    open($cfgl,"<","/etc/xcat/cfgloc");
	    $xcatcfg = <$cfgl>;
	    close($cfgl);
	    chomp($xcatcfg);
	    $ENV{'XCATCFG'}=$xcatcfg; #Store it in env to avoid many file reads
        }
    }
    if ($xcatcfg =~ /^$/)
    {
        if (-d "/opt/xcat/cfg")
        {
            $xcatcfg = "SQLite:/opt/xcat/cfg";
        }
        else
        {
            if (-d "/etc/xcat")
            {
                $xcatcfg = "SQLite:/etc/xcat";
            }
        }
    }
    ($xcatcfg =~ /^$/) && die "Can't locate xCAT configuration";
    unless ($xcatcfg =~ /:/)
    {
        $xcatcfg = "SQLite:" . $xcatcfg;
    }
    return $xcatcfg;
}

#--------------------------------------------------------------------------

=head3   new

    Description: Constructor: Connects to  or Creates Database Table


    Arguments:  Table name
                0 = Connect to table
				1 = Create table
    Returns:
               Hash: Database Handle, Statement Handle, nodelist
    Globals:

    Error:

    Example:
       $nodelisttab = xCAT::Table->new("nodelist");
    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub new
{
    #Constructor takes table name as argument
    #Also takes a true/false value, or assumes 0.  If something true is passed, create table
    #is requested
    my @args = @_;
    my $self  = {};
    my $proto = shift;
    $self->{tabname} = shift;
    unless (defined($xCAT::Schema::tabspec{$self->{tabname}})) { return undef; }
    $self->{schema}   = $xCAT::Schema::tabspec{$self->{tabname}};
    $self->{colnames} = \@{$self->{schema}->{cols}};
    $self->{descriptions} = \%{$self->{schema}->{descriptions}};
    my %otherargs  = @_;
    my $create = 1;
    if (exists($otherargs{'-create'}) && ($otherargs{'-create'}==0)) {$create = 0;}
    $self->{autocommit} = $otherargs{'-autocommit'};
    unless (defined($self->{autocommit}))
    {
        $self->{autocommit} = 1;
    }
    my $class = ref($proto) || $proto;
    if ($dbworkerpid) {
        my $request = { 
            function => "new",
            tablename => $self->{tabname},
            autocommit => $self->{autocommit},
            args=>\@args,
        };
        unless (dbc_submit($request)) {
            return undef;
        }
    } else { #direct db access mode
        $self->{dbuser}="";
        $self->{dbpass}="";

	my $xcatcfg =get_xcatcfg();

        if ($xcatcfg =~ /^SQLite:/)
        {
            $self->{backend_type} = 'sqlite';
            my @path = split(':', $xcatcfg, 2);
            unless (-e $path[1] . "/" . $self->{tabname} . ".sqlite" || $create)
            {
                return undef;
            }
            $self->{connstring} =
              "dbi:" . $xcatcfg . "/" . $self->{tabname} . ".sqlite";
        }
        elsif ($xcatcfg =~ /^CSV:/)
        {
            $self->{backend_type} = 'csv';
            $xcatcfg =~ m/^.*?:(.*)$/;
            my $path = $1;
            $self->{connstring} = "dbi:CSV:f_dir=" . $path;
        }
        else #Generic DBI
        {
           ($self->{connstring},$self->{dbuser},$self->{dbpass}) = split(/\|/,$xcatcfg);
           $self->{connstring} =~ s/^dbi://;
           $self->{connstring} =~ s/^/dbi:/;
            #return undef;
        }
        my $oldumask= umask 0077;
        unless ($::XCAT_DBHS->{$self->{connstring},$self->{dbuser},$self->{dbpass},$self->{autocommit}}) { #= $self->{tabname};
          $::XCAT_DBHS->{$self->{connstring},$self->{dbuser},$self->{dbpass},$self->{autocommit}} =
            DBI->connect($self->{connstring}, $self->{dbuser}, $self->{dbpass}, {AutoCommit => $self->{autocommit}});
         }
         umask $oldumask;

        $self->{dbh} = $::XCAT_DBHS->{$self->{connstring},$self->{dbuser},$self->{dbpass},$self->{autocommit}};
        #Store the Table object reference as afflicted by changes to the DBH
        #This for now is ok, as either we aren't in DB worker mode, in which case this structure would be short lived...
        #or we are in db worker mode, in which case Table objects live indefinitely
        #TODO: be able to reap these objects sanely, just in case
        push @{$dbobjsforhandle->{$::XCAT_DBHS->{$self->{connstring},$self->{dbuser},$self->{dbpass},$self->{autocommit}}}},\$self;
          #DBI->connect($self->{connstring}, $self->{dbuser}, $self->{dbpass}, {AutoCommit => $autocommit});
        if ($xcatcfg =~ /^SQLite:/)
        {
            my $dbexistq =
              "SELECT name from sqlite_master WHERE type='table' and name = ?";
            my $sth = $self->{dbh}->prepare($dbexistq);
            $sth->execute($self->{tabname});
            my $result = $sth->fetchrow();
            $sth->finish;
            unless (defined $result)
            {
                if ($create)
                {
                    my $str =
                      buildcreatestmt($self->{tabname},
                                      $xCAT::Schema::tabspec{$self->{tabname}},
                      $xcatcfg);
                    $self->{dbh}->do($str);
                }
                else { return undef; }
            }
        }
        elsif ($xcatcfg =~ /^CSV:/)
        {
            $self->{dbh}->{'csv_tables'}->{$self->{tabname}} =
              {'file' => $self->{tabname} . ".csv"};
            $xcatcfg =~ m/^.*?:(.*)$/;
            my $path = $1;
            if (!-e $path . "/" . $self->{tabname} . ".csv")
            {
                unless ($create)
                {
                    return undef;
                }
                my $str =
                  buildcreatestmt($self->{tabname},
                                  $xCAT::Schema::tabspec{$self->{tabname}},
                      $xcatcfg);
                $self->{dbh}->do($str);
            }
        } else { #generic DBI
           my $tbexistq = $self->{dbh}->table_info('','',$self->{tabname},'TABLE');
        my $found = 0;
           while (my $data = $tbexistq->fetchrow_hashref) {
        if ($data->{'TABLE_NAME'} =~ /^\"?$self->{tabname}\"?\z/) {
            $found = 1;
            last;
        }
        }
        unless ($found) {
            unless ($create)
            {
               return undef;
            }
            my $str =
               buildcreatestmt($self->{tabname},
                               $xCAT::Schema::tabspec{$self->{tabname}},
                       $xcatcfg);
            $self->{dbh}->do($str);
        }
         }


       updateschema($self, $xcatcfg);
    } #END DB ACCESS SPECIFIC SECTION
    if ($self->{tabname} eq 'nodelist')
    {
        weaken($self->{nodelist} = $self);
    }
    else
    {
        $self->{nodelist} = xCAT::Table->new('nodelist',-create=>1);
    }
    bless($self, $class);
    return $self;
}

#--------------------------------------------------------------------------

=head3  updateschema

    Description: Alters table schema

    Arguments: Hash containing Database and Table Handle and schema

    Returns: None

    Globals:

    Error:

    Example:
		  $self->{tabname} = shift;
          $self->{schema}   = $xCAT::Schema::tabspec{$self->{tabname}};
          $self->{colnames} = \@{$self->{schema}->{cols}};
          updateschema($self);
    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub updateschema
{

    #This determines alter table statements required..
    my $self = shift;
    my $xcatcfg = shift;
    my $descr=$xCAT::Schema::tabspec{$self->{tabname}};
    my $tn=$self->{tabname};

    my @columns;
    my %dbkeys;
    if ($self->{backend_type} eq 'sqlite')
    {
        my $dbexistq =
          "PRAGMA table_info('$tn')";
        my $sth = $self->{dbh}->prepare($dbexistq);
        $sth->execute;
            my $tn=$self->{tabname};
        while ( my $col_info = $sth->fetchrow_hashref ) {
	    #print Dumper($col_info);
            my $tmp_col=$col_info->{name};
            $tmp_col =~ s/"//g;
	    push @columns, $tmp_col;
	    if ($col_info->{pk}) {
		$dbkeys{$tmp_col}=1;
	    }
	}
        $sth->finish;
    } else { #Attempt generic dbi..
       #my $sth = $self->{dbh}->column_info('','',$self->{tabname},'');
       my $sth = $self->{dbh}->column_info(undef,undef,$self->{tabname},'%'); 
       while (my $cd = $sth->fetchrow_hashref) {
           #print Dumper($cd);
           push @columns,$cd->{'COLUMN_NAME'};

           #special code for old version of perl-DBD-mysql
           if (exists($cd->{mysql_is_pri_key}) && ($cd->{mysql_is_pri_key}==1)) {
               my $tmp_col=$cd->{'COLUMN_NAME'};
               $tmp_col =~ s/"//g;
               $dbkeys{$tmp_col}=1;
 	   }
       }
	foreach (@columns) { #Column names may end up quoted by database engin
		s/"//g;
	}

       #get primary keys
       $sth = $self->{dbh}->primary_key_info(undef,undef,$self->{tabname});
       if ($sth) {
           my $data = $sth->fetchall_arrayref;
           #print "data=". Dumper($data);
           foreach my $cd (@$data) {
               my $tmp_col=$cd->[3];
               $tmp_col =~ s/"//g;
               $dbkeys{$tmp_col}=1;
           }      
        }
    }

    #Now @columns reflects the *actual* columns in the database
    my $dcol;
    my $types=$descr->{types};

    foreach $dcol (@{$self->{colnames}})
    {
        unless (grep /^$dcol$/, @columns)
        {
            #TODO: log/notify of schema upgrade?
            my $datatype=get_datatype_string($dcol, $xcatcfg, $types);
	    if ($datatype eq "TEXT") {
		if (isAKey(\@{$descr->{keys}}, $dcol)) {   # keys need defined length
		    $datatype = "VARCHAR(128)";
		}
	    }

	    if (grep /^$dcol$/, @{$descr->{required}})
	    {
		$datatype .= " NOT NULL";
	    }
            my $stmt =
                  "ALTER TABLE " . $self->{tabname} . " ADD $dcol $datatype";
            $self->{dbh}->do($stmt);
        }
    }

    #for existing columns that are new keys now,
    my @new_dbkeys=@{$descr->{keys}};
    my @old_dbkeys=keys %dbkeys;
    #print "new_dbkeys=@new_dbkeys;  old_dbkeys=@old_dbkeys; columns=@columns\n";
    my $change_keys=0;
    foreach my $dbkey (@new_dbkeys) {
        if (! exists($dbkeys{$dbkey})) { 
	    $change_keys=1; 
            #for my sql, we do not have to recreate table, but we have to make sure the type is correct, 
            #TEXT is not a valid type for a primary key
	    if ($xcatcfg =~ /^mysql:/) {  
		my $datatype=get_datatype_string($dbkey, $xcatcfg, $types);
		if ($datatype eq "TEXT") {
		    if (isAKey(\@{$descr->{keys}}, $dbkey)) {   # keys need defined length
			$datatype = "VARCHAR(128)";
		    }
		}
		
		if (grep /^$dbkey$/, @{$descr->{required}})
		{
		    $datatype .= " NOT NULL";
		}
		my $stmt =
		    "ALTER TABLE " . $self->{tabname} . " MODIFY COLUMN $dbkey $datatype";
		print "stmt=$stmt\n";
		$self->{dbh}->do($stmt);
		if ($self->{dbh}->errstr) {
		    xCAT::MsgUtils->message("S", "Error changing the keys for table " . $self->{tabname} .":" . $self->{dbh}->errstr);
		}
	    }
        }
    }
    #check for cloumns that used to be keys but now are not
    if (!$change_keys) {
	foreach(keys %dbkeys) {
	    if (! isAKey(\@new_dbkeys, $_)) { 
		$change_keys=1;
		last;
	    }
	}
    }

    #finaly drop the old keys and add the new keys
    if ($change_keys) {
	if ($xcatcfg =~ /^mysql:/) {  #for mysql, just alter the table
	    my $tmp=join(',',@new_dbkeys); 
	    my $stmt =
	        "ALTER TABLE " . $self->{tabname} . " DROP PRIMARY KEY, ADD PRIMARY KEY ($tmp)";
	    print "stmt=$stmt\n";
	    $self->{dbh}->do($stmt);
            if ($self->{dbh}->errstr) {
		xCAT::MsgUtils->message("S", "Error changing the keys for table " . $self->{tabname} .":" . $self->{dbh}->errstr);
	    }
	} else { #for the rest, recreate the table
            print "need to change keys\n";
            my $btn=$tn . "_xcatbackup";
            
            #remove the backup table just in case;
            my $str="DROP TABLE $btn";
	    $self->{dbh}->do($str);

	    #rename the table name to name_xcatbackup
	    $str = "ALTER TABLE $tn RENAME TO $btn";
	    $self->{dbh}->do($str);
	    if ($self->{dbh}->errstr) {
		xCAT::MsgUtils->message("S", "Error renaming the table from $tn to $btn:" . $self->{dbh}->errstr);
	    }

	    #create the table again
	    $str = 
                  buildcreatestmt($tn,
                                  $descr,
				  $xcatcfg);
	    $self->{dbh}->do($str);
	    if ($self->{dbh}->errstr) {
		xCAT::MsgUtils->message("S", "Error recreating table $tn:" . $self->{dbh}->errstr);
	    }

            #copy the data from backup to the table
            $str = "INSERT INTO $tn SELECT * FROM $btn";
	    $self->{dbh}->do($str);
	    if ($self->{dbh}->errstr) {
		xCAT::MsgUtils->message("S", "Error copying data from table $btn to $tn:" . $self->{dbh}->errstr);
	    } else {
		#drop the backup table
		$str = "DROP TABLE $btn";
		$self->{dbh}->do($str);
	    }
	}
    }
}

#--------------------------------------------------------------------------

=head3  setNodeAttribs

    Description: Set attributes values on the node input to the routine

    Arguments:
               Hash: Database Handle, Statement Handle, nodelist
               Node name
			   Attribute hash
    Returns:

    Globals:

    Error:

    Example:
       my $mactab = xCAT::Table->new('mac',-create=>1);
	   $mactab->setNodeAttribs($node,{mac=>$mac});
	   $mactab->close();

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub setNodeAttribs
{
    my $self = shift;
    my $node = shift;
    return $self->setAttribs({'node' => $node}, @_);
}

#--------------------------------------------------------------------------

=head3  addNodeAttribs

    Description: Add new attributes input to the routine to the nodes

    Arguments:
           Hash of new attributes
    Returns:

    Globals:

    Error:

    Example:

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub addNodeAttribs
{
    my $self = shift;
    return $self->addAttribs('node', @_);
}

#--------------------------------------------------------------------------

=head3  addAttribs

    Description: add new attributes

    Arguments:
               Hash: Database Handle, Statement Handle, nodelist
               Key name
		       Key value
			   Hash reference of column-value pairs to set
    Returns:

    Globals:

    Error:

    Example:

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub addAttribs
{
    my $self   = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'addAttribs',@_);
    }
    my $key    = shift;
    my $keyval = shift;
    my $elems  = shift;
    my $cols   = "";
    my @bind   = ();
    @bind = ($keyval);
    $cols = "$key,";

    for my $col (keys %$elems)
    {
        $cols = $cols . $col . ",";
        if (ref($$elems{$col}))
        {
            push @bind, ${$elems}{$col}->[0];
        }
        else
        {
            push @bind, $$elems{$col};
        }
    }
    chop($cols);
    my $qstring = 'INSERT INTO ' . $self->{tabname} . " ($cols) VALUES (";
    for (@bind)
    {
        $qstring = $qstring . "?,";
    }
    $qstring =~ s/,$/)/;
    my $sth = $self->{dbh}->prepare($qstring);
    $sth->execute(@bind);

    #$self->{dbh}->commit;

    #notify the interested parties
    my $notif = xCAT::NotifHandler->needToNotify($self->{tabname}, 'a');
    if ($notif == 1)
    {
        my %new_notif_data;
        $new_notif_data{$key} = $keyval;
        foreach (keys %$elems)
        {
            $new_notif_data{$_} = $$elems{$_};
        }
        xCAT::NotifHandler->notify("a", $self->{tabname}, [0],
                                          \%new_notif_data);
    }

}

#--------------------------------------------------------------------------

=head3 rollback

    Description:  rollback changes

    Arguments:
              Database Handle
    Returns:
           none
    Globals:

    Error:

    Example:

       my $tab = xCAT::Table->new($table,-create =>1,-autocommit=>0);
	   $tab->rollback();

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub rollback
{
    my $self = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'rollback',@_);
    }
    $self->{dbh}->rollback;
}

#--------------------------------------------------------------------------

=head3 commit

    Description:
             Commit changes
    Arguments:
        Database Handle
    Returns:
       none
    Globals:

    Error:

    Example:
       my $tab = xCAT::Table->new($table,-create =>1,-autocommit=>0);
	   $tab->commit();

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub commit
{
    my $self = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'commit',@_);
    }
    $self->{dbh}->commit;
}

#--------------------------------------------------------------------------

=head3 setAttribs

    Description:

    Arguments:
         Key name
		 Key value
		 Hash reference of column-value pairs to set

    Returns:
         None
    Globals:

    Error:

    Example:
       my $tab = xCAT::Table->new( 'ppc', -create=>1, -autocommit=>0 );
	   $keyhash{'node'}    = $name;
	   $updates{'type'}    = lc($type);
	   $updates{'id'}      = $lparid;
	   $updates{'hcp'}     = $server;
	   $updates{'profile'} = $prof;
	   $updates{'frame'}   = $frame;
	   $updates{'mtms'}    = "$model*$serial";
	   $tab->setAttribs( \%keyhash,\%updates );
	   $tab->commit;

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub setAttribs
{

    #Takes three arguments:
    #-Key name
    #-Key value
    #-Hash reference of column-value pairs to set
    my $self     = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'setAttribs',@_);
    }
    my $pKeypairs=shift;
    my %keypairs = ();
    if ($pKeypairs != undef) { %keypairs = %{$pKeypairs}; }

    #my $key = shift;
    #my $keyval=shift;
    my $elems = shift;
    my $cols  = "";
    my @bind  = ();
    my $action;
    my @notif_data;
    my $qstring = "SELECT * FROM " . $self->{tabname} . " WHERE ";
    my @qargs   = ();
    my $query;
    my $data;

    if (($pKeypairs != undef) && (keys(%keypairs)>0)) {
	foreach (keys %keypairs)
	{
	    #$qstring .= "$_ = ? AND "; #mysql changes
	    #push @qargs, $keypairs{$_};
	    $qstring .= "\"$_\" = ? AND ";
	    push @qargs, $keypairs{$_};
	    
	}
	$qstring =~ s/ AND \z//;
	$query = $self->{dbh}->prepare($qstring);
	$query->execute(@qargs);
	
	#get the first row
	$data = $query->fetchrow_arrayref();
	if (defined $data)
	{
	    $action = "u";
	}
	else
	{
	    $action = "a";
	}
    } else { $action = "a";}

    #prepare the notification data
    my $notif =
      xCAT::NotifHandler->needToNotify($self->{tabname}, $action);
    if ($notif == 1)
    {
        if ($action eq "u")
        {

            #put the column names at the very front
            push(@notif_data, $query->{NAME});

            #copy the data out because fetchall_arrayref overrides the data.
            my @first_row = @$data;
            push(@notif_data, \@first_row);

            #get the rest of the rows
            my $temp_data = $query->fetchall_arrayref();
            foreach (@$temp_data)
            {
                push(@notif_data, $_);
            }
        }
    }

    if ($query) {
	$query->finish();
    }

    if ($action eq "u")
    {

        #update the rows
        $action = "u";
        for my $col (keys %$elems)
        {
            $cols = $cols . $col . " = ?,";
            push @bind, (($$elems{$col} =~ /NULL/) ? undef: $$elems{$col});
        }
        chop($cols);
        my $cmd = "UPDATE " . $self->{tabname} . " set $cols where ";
        foreach (keys %keypairs)
        {
            if (ref($keypairs{$_}))
            {
                $cmd .= "\"$_\"" . " = '" . $keypairs{$_}->[0] . "' AND ";
            }
            else
            {
                $cmd .= "\"$_\"" . " = '" . $keypairs{$_} . "' AND ";
            }
        }
        $cmd =~ s/ AND \z//;
        my $sth = $self->{dbh}->prepare($cmd);
        unless ($sth) {
            return (undef,"Error attempting requested DB operation");
        }
        my $err = $sth->execute(@bind);
        if (not defined($err))
        {
            return (undef, $sth->errstr);
        }
	$sth->finish;
    }
    else
    {
        #insert the rows
        $action = "a";
        @bind   = ();
        $cols   = "";
	my %newpairs;
	#first, merge the two structures to a single hash
        foreach (keys %keypairs)
        {
	    $newpairs{$_} = $keypairs{$_};
	}
        for my $col (keys %$elems)
        {
	    $newpairs{$col} = $$elems{$col};
        }
	foreach (keys %newpairs) {
            #$cols .= $_ . ",";  # mysql changes
            $cols .= "\"$_\"" . ",";
            push @bind, $newpairs{$_};
        }
        chop($cols);
        my $qstring = 'INSERT INTO ' . $self->{tabname} . " ($cols) VALUES (";
        for (@bind)
        {
            $qstring = $qstring . "?,";
        }
        $qstring =~ s/,$/)/;
        my $sth = $self->{dbh}->prepare($qstring);
        my $err = $sth->execute(@bind);
        if (not defined($err))
        {
            return (undef, $sth->errstr);
        }
	$sth->finish;
    }

    #notify the interested parties
    if ($notif == 1)
    {
        #create new data ref
        my %new_notif_data = %keypairs;
        foreach (keys %$elems)
        {
            $new_notif_data{$_} = $$elems{$_};
        }
        xCAT::NotifHandler->notify($action, $self->{tabname},
                                          \@notif_data, \%new_notif_data);
    }
    return 0;
}

#--------------------------------------------------------------------------

=head3 setAttribsWhere

    Description:
       This function sets the attributes for the rows selected by the where clause.
    Arguments:
         Where clause.
	 Hash reference of column-value pairs to set
    Returns:
         None
    Globals:
    Error:
    Example:
       my $tab = xCAT::Table->new( 'ppc', -create=>1, -autocommit=>1 );
	   $updates{'type'}    = lc($type);
	   $updates{'id'}      = $lparid;
	   $updates{'hcp'}     = $server;
	   $updates{'profile'} = $prof;
	   $updates{'frame'}   = $frame;
	   $updates{'mtms'}    = "$model*$serial";
	   $tab->setAttribs( "node in ('node1', 'node2', 'node3')", \%updates );
    Comments:
        none
=cut
#--------------------------------------------------------------------------------
sub setAttribsWhere
{
    #Takes three arguments:
    #-Where clause
    #-Hash reference of column-value pairs to set
    my $self     = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'setAttribsWhere',@_);
    }
    my $where_clause = shift;
    my $elems = shift;
    my $cols  = "";
    my @bind  = ();
    my $action;
    my @notif_data;
    my $qstring = "SELECT * FROM " . $self->{tabname} . " WHERE " . $where_clause;
    my @qargs   = ();
    my $query = $self->{dbh}->prepare($qstring);
    $query->execute(@qargs);

    #get the first row
    my $data = $query->fetchrow_arrayref();
    if (defined $data){  $action = "u";}
    else { return (0, "no rows selected."); }

    #prepare the notification data
    my $notif =
      xCAT::NotifHandler->needToNotify($self->{tabname}, $action);
    if ($notif == 1)
    {
      #put the column names at the very front
      push(@notif_data, $query->{NAME});

      #copy the data out because fetchall_arrayref overrides the data.
      my @first_row = @$data;
      push(@notif_data, \@first_row);
      #get the rest of the rows
      my $temp_data = $query->fetchall_arrayref();
      foreach (@$temp_data) {
        push(@notif_data, $_);
      }
    }

    $query->finish();

    #update the rows
    for my $col (keys %$elems)
    {
      $cols = $cols . $col . " = ?,";
      push @bind, (($$elems{$col} =~ /NULL/) ? undef: $$elems{$col});
    }
    chop($cols);
    my $cmd = "UPDATE " . $self->{tabname} . " set $cols where " . $where_clause;
    my $sth = $self->{dbh}->prepare($cmd);
    my $err = $sth->execute(@bind);
    if (not defined($err))
    {
      return (undef, $sth->errstr);
    }

    #notify the interested parties
    if ($notif == 1)
    {
      #create new data ref
      my %new_notif_data = ();
      foreach (keys %$elems)
      {
        $new_notif_data{$_} = $$elems{$_};
      }
      xCAT::NotifHandler->notify($action, $self->{tabname},
                                 \@notif_data, \%new_notif_data);
    }
    $sth->finish;
    return 0;
}


#--------------------------------------------------------------------------
=head3 setNodesAttribs

    Description: Unconditionally assigns the requested values to tables for a list of nodes

    Arguments:
        'self' (implicit in OO style call)
        Reference to a list of nodes (no noderanges, just nodes)
        A hash of attributes to set, like in 'setNodeAttribs'

    Returns:
=cut
#--------------------------------------------------------------------------
sub setNodesAttribs {
#This is currently a stub to be filled out with at scale enhancements.  It will be a touch more complex than getNodesAttribs, due to the notification
#The three steps should be:
#-Query table and divide nodes into list to update and list to insert
#-Update intelligently with respect to scale
#-Insert intelligently with respect to scale
#Intelligently in this case means folding them to some degree.  Update where clauses will be longer, but must be capped to avoid exceeding SQL statement length restrictions on some DBs.  Restricting even all the way down to 256 could provide better than an order of magnitude better performance though
    my $self = shift;
    my $nodelist = shift;
    foreach  (@$nodelist) {
        $self->setNodeAttribs($_,@_);
    }
}

#--------------------------------------------------------------------------

=head3 getNodesAttribs

    Description: Retrieves the requested attributes for a node list

    Arguments:
            Table handle ('self')
			List ref of nodes
	        Attribute type array
    Returns:

			two layer hash reference (->{nodename}->{attrib} 
    Globals:

    Error:

    Example:
           my $ostab = xCAT::Table->new('nodetype');
		   my $ent = $ostab->getNodesAttribs(\@nodes,['profile','os','arch']);
           if ($ent) { print $ent->{n1}->{profile}

    Comments:
        Using this function will clue the table layer into the atomic nature of the request, and allow shortcuts to be taken as appropriate to fulfill the request at scale.

=cut

#--------------------------------------------------------------------------------
sub getNodesAttribs {
    my $self = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'getNodesAttribs',@_);
    }
    my $nodelist = shift;
    my @attribs;
    if (ref $_[0]) {
        @attribs = @{shift()};
    } else {
        @attribs = @_;
    }
    if (scalar($nodelist) > $cachethreshold) {
        $self->{_use_cache} = 0;
        $self->{nodelist}->{_use_cache}=0;
        if ($self->{tabname} eq 'nodelist') { #a sticky situation
            my @locattribs=@attribs;
            unless (grep(/^node$/,@locattribs)) {
                push @locattribs,'node';
            }
            unless (grep(/^groups$/,@locattribs)) {
                push @locattribs,'node';
            }
            $self->_build_cache(\@locattribs);
        } else {
            $self->_build_cache(\@attribs);
            $self->{nodelist}->_build_cache(['node','groups']);
        }
        $self->{_use_cache} = 1;
        $self->{nodelist}->{_use_cache}=1;
    }
    my $rethash;
    foreach (@$nodelist) {
        my @nodeentries=$self->getNodeAttribs($_,\@attribs);
        $rethash->{$_} = \@nodeentries; #$self->getNodeAttribs($_,\@attribs);
    }
    $self->_clear_cache;
    $self->{_use_cache} = 0;
    $self->{nodelist}->_clear_cache;
    $self->{nodelist}->{_use_cache} = 0;
    return $rethash;
}

sub _clear_cache { #PRIVATE FUNCTION TO EXPIRE CACHED DATA EXPLICITLY
    #This is no longer sufficient to do at destructor time, as Table objects actually live an indeterminite amount of time now
    #TODO: only clear cache if ref count mentioned in build_cache is 1, otherwise decrement ref count
    my $self = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'_clear_cache',$_);
    }
    if ($self->{_cache_ref} > 1) { #don't clear the cache if there are still live references
        $self->{_cache_ref} -= 1;
        return;
    } elsif ($self->{_cache_ref} == 1) { #If it is 1, decrement to zero and carry on
        $self->{_cache_ref} = 0;
    }
    #it shouldn't have been zero, but whether it was 0 or 1, ensure that the cache is gone
    $self->{_use_cache}=0; # Signal slow operation to any in-flight operations that may fail with empty cache
    undef $self->{_tablecache};
    undef $self->{_nodecache};
}

sub _build_cache { #PRIVATE FUNCTION, PLEASE DON'T CALL DIRECTLY
#TODO: increment a reference counter type thing to preserve current cache
#Also, if ref count is 1 or greater, and the current cache is less than 3 seconds old, reuse the cache?
    my $self = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'_build_cache',@_);
    }
    if ($self->{_cache_ref}) { #we have active cache reference, increment counter and return
        #TODO: ensure that the cache isn't somehow still ludirously old
        $self->{_cache_ref} += 1;
        return;
    }
    #If here, _cache_ref indicates no cache
    $self->{_cache_ref} = 1;
    my $oldusecache = $self->{_use_cache}; #save previous 'use_cache' setting
    $self->{_use_cache} = 0; #This function must disable cache 
                            #to function
    my $attriblist = shift;
    my $nodekey = "node";
    if (defined $xCAT::Schema::tabspec{$self->{tabname}}->{nodecol}) {
        $nodekey = $xCAT::Schema::tabspec{$self->{tabname}}->{nodecol}
    };
    unless (grep /^$nodekey$/,@$attriblist) {
        push @$attriblist,$nodekey;
    }
    my @tabcache = $self->getAllAttribs(@$attriblist);
    $self->{_tablecache} = \@tabcache;
    $self->{_nodecache}  = {};
    if ($tabcache[0]->{$nodekey}) {
        foreach(@tabcache) {
            push @{$self->{_nodecache}->{$_->{$nodekey}}},$_;
        }
    }

    $self->{_use_cache} = $oldusecache; #Restore setting to previous value
    $self->{_cachestamp} = time;
}
#--------------------------------------------------------------------------

=head3 getNodeAttribs

    Description: Retrieves the requested attribute

    Arguments:
            Table handle
			Noderange
	        Attribute type array
    Returns:

			Attribute hash ( key attribute type)
    Globals:

    Error:

    Example:
           my $ostab = xCAT::Table->new('nodetype');
		   my $ent = $ostab->getNodeAttribs($node,['profile','os','arch']);

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub getNodeAttribs
{
    my $self    = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'getNodeAttribs',@_);
    }
    my $node    = shift;
    my @attribs;
    if (ref $_[0]) {
        @attribs = @{shift()};
    } else {
        @attribs = @_;
    }
    my $datum;
    my @data = $self->getNodeAttribs_nosub($node, \@attribs);
    #my ($datum, $extra) = $self->getNodeAttribs_nosub($node, \@attribs);
    #if ($extra) { return undef; }    # return (undef,"Ambiguous query"); }
    defined($data[0])
      || return undef;    #(undef,"No matching entry found in configuration");
    my $attrib;
    foreach $datum (@data) {
    foreach $attrib (@attribs)
    {
        unless (defined $datum->{$attrib}) {
            #skip undefined values, save time
            next;
        }

        if ($datum->{$attrib} =~ /^\/[^\/]*\/[^\/]*\/$/)
        {
            my $exp = substr($datum->{$attrib}, 1);
            chop $exp;
            my @parts = split('/', $exp, 2);
            $node =~ s/$parts[0]/$parts[1]/;
            $datum->{$attrib} = $node;
        }
        elsif ($datum->{$attrib} =~ /^\|.*\|.*\|$/)
        {

            #Perform arithmetic and only arithmetic operations in bracketed issues on the right.
            #Tricky part:  don't allow potentially dangerous code, only eval if
            #to-be-evaled expression is only made up of ()\d+-/%$
            #Futher paranoia?  use Safe module to make sure I'm good
            my $exp = substr($datum->{$attrib}, 1);
            chop $exp;
            my @parts = split('\|', $exp, 2);
            my $curr;
            my $next;
            my $prev;
            my $retval = $parts[1];
            ($curr, $next, $prev) =
              extract_bracketed($retval, '()', qr/[^()]*/);

            unless($curr) { #If there were no paramaters to save, treat this one like a plain regex
               $retval = $node;
               $retval =~ s/$parts[0]/$parts[1]/;
               $datum->{$attrib} = $retval;
               if ($datum->{$attrib} =~ /^$/) {
                  #If regex forces a blank, act like a normal blank does
                  delete $datum->{$attrib};
               }
               next; #skip the redundancy that follows otherwise
            }
            while ($curr)
            {

                #my $next = $comps[0];
                if ($curr =~ /^[\{\}()\-\+\/\%\*\$\d]+$/ or $curr =~ /^\(sprintf\(["'%\dcsduoxefg]+,\s*[\{\}()\-\+\/\%\*\$\d]+\)\)$/ )
                {
                    use integer
                      ; #We only allow integer operations, they are the ones that make sense for the application
                    my $value = $node;
                    $value =~ s/$parts[0]/$curr/ee;
                    $retval = $prev . $value . $next;
                }
                else
                {
                    print "$curr is bad\n";
                }
                ($curr, $next, $prev) =
                  extract_bracketed($retval, '()', qr/[^()]*/);
            }
            #At this point, $retval is the expression after being arithmetically contemplated, a generated regex, and therefore
            #must be applied in total
            my $answval = $node;
            $answval =~ s/$parts[0]/$retval/;
            $datum->{$attrib} = $answval; #$retval;

            #print Data::Dumper::Dumper(extract_bracketed($parts[1],'()',qr/[^()]*/));
            #use text::balanced extract_bracketed to parse earch atom, make sure nothing but arith operators, parans, and numbers are in it to guard against code execution
        }
        if ($datum->{$attrib} =~ /^$/) {
            #If regex forces a blank, act like a normal blank does
            delete $datum->{$attrib};
        }
    }
    }
    return wantarray ? @data : $data[0];
}

#--------------------------------------------------------------------------

=head3 getNodeAttribs_nosub

    Description:

    Arguments:

    Returns:

    Globals:

    Error:

    Example:

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub getNodeAttribs_nosub
{
    my $self   = shift;
    my $node   = shift;
    my $attref = shift;
    my @data;
    my $datum;
    my @tents;
    my $return = 0;
    @tents = $self->getNodeAttribs_nosub_returnany($node, $attref);
    foreach my $tent (@tents) {
      $datum={};
      foreach (@$attref)
      {
        if ($tent and defined($tent->{$_}))
        {
           $return = 1;
           $datum->{$_} = $tent->{$_};
        } else { #attempt to fill in gapped attributes
           unless (scalar(@$attref) <= 1) {
             my $sent = $self->getNodeAttribs($node, [$_]);
             if ($sent and defined($sent->{$_})) {
                 $return = 1;
                 $datum->{$_} = $sent->{$_};
             }
           }
        }
      }
      push(@data,$datum);
    }
    if ($return)
    {
        return wantarray ? @data : $data[0];
    }
    else
    {
        return undef;
    }
}

#--------------------------------------------------------------------------

=head3 getNodeAttribs_nosub_returnany

    Description:

    Arguments:

    Returns:

    Globals:

    Error:

    Example:

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub getNodeAttribs_nosub_returnany
{    #This is the original function
    my $self    = shift;
    my $node    = shift;
    my @attribs = @{shift()};
    my @results;

    #my $recurse = ((scalar(@_) == 1) ?  shift : 1);
    my $nodekey = "node";
    if (defined $xCAT::Schema::tabspec{$self->{tabname}}->{nodecol}) {
        $nodekey = $xCAT::Schema::tabspec{$self->{tabname}}->{nodecol}
    };
    @results = $self->getAttribs({$nodekey => $node}, @attribs);
    my $data = $results[0];
    if (!defined($data))
    {
        my ($nodeghash) =
          $self->{nodelist}->getAttribs({node => $node}, 'groups');
        unless (defined($nodeghash) && defined($nodeghash->{groups}))
        {
            return undef;
        }
        my @nodegroups = split(/,/, $nodeghash->{groups});
        my $group;
        foreach $group (@nodegroups)
        {
            @results = $self->getAttribs({$nodekey => $group}, @attribs);
	    $data = $results[0];
            if ($data != undef)
            {
                foreach (@results) {
                   if ($_->{node}) { $_->{node} = $node; }
                };
                return @results;
            }
        }
    }
    else
    {

        #Don't need to 'correct' node attribute, considering result of the if that governs this code block?
        return @results;
    }
    return undef;    #Made it here, config has no good answer
}

#--------------------------------------------------------------------------

=head3 getAllEntries

    Description:  Read entire table

    Arguments:
           Table handle
           "all" return all lines ( even disabled)
           Default is to return only lines that have not been disabled

    Returns:
       Hash containing all rows in table
    Globals:

    Error:

    Example:

	 my $tabh = xCAT::Table->new($table);
         my $recs=$tabh->getAllEntries(); # returns entries not disabled
         my $recs=$tabh->getAllEntries("all"); # returns all  entries

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub getAllEntries
{
    my $self = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'getAllEntries',@_);
    }
    my $allentries = shift;
    my @rets;
    my $query;

    if ($allentries) { # get all lines
     $query = $self->{dbh}->prepare('SELECT * FROM ' . $self->{tabname});
    } else {  # get only enabled lines
      $query = $self->{dbh}->prepare('SELECT * FROM '
                . $self->{tabname}
              . " WHERE \"disable\" is NULL or \"disable\" in ('','0','no','NO','no')");
    }

    $query->execute();
    while (my $data = $query->fetchrow_hashref())
    {
        foreach (keys %$data)
        {
            if ($data->{$_} =~ /^$/)
            {
                $data->{$_} = undef;
            }
        }
        push @rets, $data;
    }
    $query->finish();
    return \@rets;
}

#--------------------------------------------------------------------------

=head3 getAllAttribsWhere

    Description:  Get all attributes with "where" clause

    Arguments:
       Database Handle
       Where clause
    Returns:
        Array of attributes
    Globals:

    Error:

    Example:
    $nodelist->getAllAttribsWhere("groups like '%".$atom."%'",'node','group');
    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub getAllAttribsWhere
{

    #Takes a list of attributes, returns all records in the table.
    my $self        = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'getAllAttribsWhere',@_);
    }
    my $whereclause = shift;
    my @attribs     = @_;
    my @results     = ();
    my $query       =
      $self->{dbh}->prepare('SELECT * FROM '
                . $self->{tabname}
                . ' WHERE ('
                . $whereclause
                . ") and (\"disable\" is NULL or \"disable\" in ('0','no','NO','no'))");
    $query->execute();
    while (my $data = $query->fetchrow_hashref())
    {
        my %newrow = ();
        foreach (@attribs)
        {
            unless ($data->{$_} =~ /^$/ || !defined($data->{$_}))
            { #The reason we do this is to undef fields in rows that may still be returned..
                $newrow{$_} = $data->{$_};
            }
        }
        if (keys %newrow)
        {
            push(@results, \%newrow);
        }
    }
    $query->finish();
    return @results;
}

#--------------------------------------------------------------------------

=head3 getAllNodeAttribs

    Description: Get all the node attributes values for the input table on the
				 attribute list

    Arguments:
                 Table handle
				 Attribute list
    Returns:
                 Array of attribute values
    Globals:

    Error:

    Example:
         my @entries = $self->{switchtab}->getAllNodeAttribs(['port','switch']);
    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub getAllNodeAttribs
{

    #Extract and substitute every node record, expanding groups and substituting as getNodeAttribs does
    my $self    = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'getAllNodeAttribs',@_);
    }
    my $attribq = shift;
    my $hashretstyle = shift;
    my $rethash;
    my @results = ();
    my %donenodes
      ; #Remember those that have been done once to not return same node multiple times
    my $query =
      $self->{dbh}->prepare('SELECT node FROM '
              . $self->{tabname}
              . " WHERE \"disable\" is NULL or \"disable\" in ('','0','no','NO','no')");
    $query->execute();
    xCAT::NodeRange::retain_cache(1);
    $self->{_use_cache} = 0;
    $self->{nodelist}->{_use_cache}=0;
    $self->_build_cache($attribq);
    $self->{nodelist}->_build_cache(['node','groups']);
    $self->{_use_cache} = 1;
    $self->{nodelist}->{_use_cache}=1;
    while (my $data = $query->fetchrow_hashref())
    {

        unless ($data->{node} =~ /^$/ || !defined($data->{node}))
        {    #ignore records without node attrib, not possible?
            my @nodes =
              xCAT::NodeRange::noderange($data->{node})
              ;    #expand node entry, to make groups expand
            #my $localhash = $self->getNodesAttribs(\@nodes,$attribq); #NOTE:  This is stupid, rebuilds the cache for every entry, FIXME
            foreach (@nodes)
            {
                if ($donenodes{$_}) { next; }
                my $attrs;
                my $nde = $_;

                #if ($self->{giveand}) { #software requests each attribute be independently inherited
                #  foreach (@attribs) {
                #    my $attr = $self->getNodeAttribs($nde,$_);
                #    $attrs->{$_}=$attr->{$_};
                #  }
                #} else {
                my @attrs =
                  $self->getNodeAttribs($_, $attribq);#@{$localhash->{$_}} #$self->getNodeAttribs($_, $attribq)
                  ;    #Logic moves to getNodeAttribs
                       #}
                 #populate node attribute by default, this sort of expansion essentially requires it.
                #$attrs->{node} = $_;
		foreach my $att (@attrs) {
			$att->{node} = $_;
		}
                $donenodes{$_} = 1;

                if ($hashretstyle) {
                    $rethash->{$_} = \@attrs; #$self->getNodeAttribs($_,\@attribs);
                } else {
                    push @results, @attrs;    #$self->getNodeAttribs($_,@attribs);
                }
            }
        }
    }
    $self->_clear_cache();
    $self->{nodelist}->_clear_cache();
    $self->{_use_cache} = 0;
    $self->{nodelist}->{_use_cache} = 0;
    xCAT::NodeRange::retain_cache(0);
    $query->finish();
    if ($hashretstyle) {
        return $rethash;
    } else {
        return @results;
    }
}

#--------------------------------------------------------------------------

=head3 getAllAttribs

    Description: Returns a list of records in the input table for the input
				 list of attributes.

    Arguments:
             Table handle
			 List of attributes
    Returns:
        Array of attribute values
    Globals:

    Error:

    Example:
        $nodelisttab = xCAT::Table->new("nodelist");
		my @attribs = ("node");
		@nodes = $nodelisttab->getAllAttribs(@attribs);
    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub getAllAttribs
{

    #Takes a list of attributes, returns all records in the table.
    my $self    = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'getAllAttribs',@_);
    }
    #print "Being asked to dump ".$self->{tabname}."for something\n";
    my @attribs = @_;
    my @results = ();
    if ($self->{_use_cache}) {
        my @results;
        my $cacheline;
        CACHELINE: foreach $cacheline (@{$self->{_tablecache}}) {
            my $attrib;
            my %rethash;
            foreach $attrib (@attribs)
            {
                unless ($cacheline->{$attrib} =~ /^$/ || !defined($cacheline->{$attrib}))
                {    #To undef fields in rows that may still be returned
                    $rethash{$attrib} = $cacheline->{$attrib};
                }
            }
            if (keys %rethash)
            {
                push @results, \%rethash;
            }
        }
        if (@results)
        {
          return @results; #return wantarray ? @results : $results[0];
        }
        return undef;
    }
    my $query   =
      $self->{dbh}->prepare('SELECT * FROM '
              . $self->{tabname}
              . " WHERE \"disable\" is NULL or \"disable\" in ('','0','no','NO','no')");
    $query->execute();
    while (my $data = $query->fetchrow_hashref())
    {
        my %newrow = ();
        foreach (@attribs)
        {
            unless ($data->{$_} =~ /^$/ || !defined($data->{$_}))
            { #The reason we do this is to undef fields in rows that may still be returned..
                $newrow{$_} = $data->{$_};
            }
        }
        if (keys %newrow)
        {
            push(@results, \%newrow);
        }
    }
    $query->finish();
    return @results;
}

#--------------------------------------------------------------------------

=head3 delEntries

    Description:  Delete table entries

    Arguments:
                Table Handle
                Entry to delete
    Returns:

    Globals:

    Error:

    Example:
	my $table=xCAT::Table->new("notification", -create => 1,-autocommit => 0);
	my %key_col = (filename=>$fname);
	$table->delEntries(\%key_col);
	$table->commit;

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub delEntries
{
    my $self   = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'delEntries',@_);
    }
    my $keyref = shift;
    my %keypairs;
    if ($keyref)
    {
        %keypairs = %{$keyref};
    }

    my $notif = xCAT::NotifHandler->needToNotify($self->{tabname}, 'd');
    my @notif_data;
    if ($notif == 1)
    {
        my $qstring = "SELECT * FROM " . $self->{tabname};
        if ($keyref) { $qstring .= " WHERE "; }
        my @qargs = ();
        foreach (keys %keypairs)
        {
            $qstring .= "\"$_\" = ? AND "; #mysql change
            #$qstring .= "$_ = ? AND ";
            push @qargs, $keypairs{$_};
        }
        $qstring =~ s/ AND \z//;
        my $query = $self->{dbh}->prepare($qstring);
        $query->execute(@qargs);

        #prepare the notification data
        #put the column names at the very front
        push(@notif_data, $query->{NAME});
        my $temp_data = $query->fetchall_arrayref();
        foreach (@$temp_data)
        {
            push(@notif_data, $_);
        }
        $query->finish();
    }

    my @stargs    = ();
    my $delstring = 'DELETE FROM ' . $self->{tabname};
    if ($keyref) { $delstring .= ' WHERE '; }
    foreach (keys %keypairs)
    {
        #$delstring .= $_ . ' = ? AND ';
        $delstring .= "\"$_\"" . ' = ? AND '; #mysql change
        if (ref($keypairs{$_}))
        {   #XML transformed data may come in mangled unreasonably into listrefs
            push @stargs, $keypairs{$_}->[0];
        }
        else
        {
            push @stargs, $keypairs{$_};
        }
    }
    $delstring =~ s/ AND \z//;
    my $stmt = $self->{dbh}->prepare($delstring);
    $stmt->execute(@stargs);
    $stmt->finish;

    #notify the interested parties
    if ($notif == 1)
    {
        xCAT::NotifHandler->notify("d", $self->{tabname}, \@notif_data,
                                          {});
    }
}

#--------------------------------------------------------------------------

=head3 getAttribs

    Description:

    Arguments:
               key
			   List of attributes
    Returns:
               Hash of requested attributes
    Globals:

    Error:

    Example:
        $table = xCAT::Table->new('passwd');
		@tmp=$table->getAttribs({'key'=>'ipmi'},('username','password');
    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub getAttribs
{

    #Takes two arguments:
    #-Node name (will be compared against the 'Node' column)
    #-List reference of attributes for which calling code wants at least one of defined
    # (recurse argument intended only for internal use.)
    # Returns a hash reference with requested attributes defined.
    my $self = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'getAttribs',@_);
    }

    #my $key = shift;
    #my $keyval = shift;
    my %keypairs = %{shift()};
    my @attribs;
    if (ref $_[0]) {
        @attribs = @{shift()};
    } else {
        @attribs  = @_;
    }
    my @return;
    if ($self->{_use_cache}) {
        my @results;
        my $cacheline;
        if (scalar(keys %keypairs) == 1 and $keypairs{node}) { #99.9% of queries look like this, optimized case
            foreach $cacheline (@{$self->{_nodecache}->{$keypairs{node}}}) {
                my $attrib;
                my %rethash;
                foreach $attrib (@attribs)
               {
                   unless ($cacheline->{$attrib} =~ /^$/ || !defined($cacheline->{$attrib}))
                 {    #To undef fields in rows that may still be returned
                     $rethash{$attrib} = $cacheline->{$attrib};
                 }
               }
               if (keys %rethash)
             {
                 push @results, \%rethash;
             }
            }
        } else { #SLOW WAY FOR GENERIC CASE
            CACHELINE: foreach $cacheline (@{$self->{_tablecache}}) {
                foreach (keys %keypairs) {
                    if (not $keypairs{$_} and $keypairs{$_} ne 0 and $cacheline->{$_}) {
                        next CACHELINE;
                    }
                    unless ($keypairs{$_} eq $cacheline->{$_}) {
                        next CACHELINE;
                    }
                }
                my $attrib;
                my %rethash;
                foreach $attrib (@attribs)
               {
                   unless ($cacheline->{$attrib} =~ /^$/ || !defined($cacheline->{$attrib}))
                 {    #To undef fields in rows that may still be returned
                     $rethash{$attrib} = $cacheline->{$attrib};
                 }
               }
               if (keys %rethash)
             {
                 push @results, \%rethash;
             }
            }
        }
        if (@results)
        {
          return wantarray ? @results : $results[0];
        }
        return undef;
    }
    #print "Uncached access to ".$self->{tabname}."\n";
    my $statement = 'SELECT * FROM ' . $self->{tabname} . ' WHERE ';
    my @exeargs;
    foreach (keys %keypairs)
    {
        if ($keypairs{$_})
        {
            $statement .= "\"".$_ . "\" = ? and ";
            if (ref($keypairs{$_}))
            {    #correct for XML process mangling if occurred
                push @exeargs, $keypairs{$_}->[0];
            }
            else
            {
                push @exeargs, $keypairs{$_};
            }
        }
        else
        {
            $statement .= "\"$_\" is NULL and ";
        }
    }
    $statement .= "(\"disable\" is NULL or \"disable\" in ('0','no','NO','No','nO'))";
    my $query = $self->{dbh}->prepare($statement);
    unless (defined $query) {
        return undef;
    }
    $query->execute(@exeargs);
    my $data;
    while ($data = $query->fetchrow_hashref())
    {
        my $attrib;
        my %rethash;
        foreach $attrib (@attribs)
        {
            unless ($data->{$attrib} =~ /^$/ || !defined($data->{$attrib}))
            {    #To undef fields in rows that may still be returned
                $rethash{$attrib} = $data->{$attrib};
            }
        }
        if (keys %rethash)
        {
            push @return, \%rethash;
        }
    }
    $query->finish();
    if (@return)
    {
      return wantarray ? @return : $return[0];
    }
    return undef;
}

#--------------------------------------------------------------------------

=head3 getTable

    Description:  Read entire Table

    Arguments:
                Table Handle

    Returns:
                Array of table rows
    Globals:

    Error:

    Example:
                  my $table=xCAT::Table->new("notification", -create =>0);
				  my @row_array= $table->getTable;
    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub getTable
{

    # Get contents of table
    # Takes no arguments
    # Returns an array of hashes containing the entire contents of this
    #   table.  Each array entry contains a pointer to a hash which is
    #   one row of the table.  The row hash is keyed by attribute name.
    my $self = shift;
    if ($dbworkerpid) {
        return dbc_call($self,'getTable',@_);
    }
    my @return;
    my $statement = 'SELECT * FROM ' . $self->{tabname};
    my $query     = $self->{dbh}->prepare($statement);
    $query->execute();
    my $data;
    while ($data = $query->fetchrow_hashref())
    {
        my $attrib;
        my %rethash;
        foreach $attrib (keys %{$data})
        {
            $rethash{$attrib} = $data->{$attrib};
        }
        if (keys %rethash)
        {
            push @return, \%rethash;
        }
    }
    $query->finish();
    if (@return)
    {
        return @return;
    }
    return undef;
}

#--------------------------------------------------------------------------

=head3 close

    Description: Close out Table transaction

    Arguments:
                Table Handle
    Returns:

    Globals:

    Error:

    Example:
                  my $mactab = xCAT::Table->new('mac');
				  $mactab->setNodeAttribs($macmap{$mac},{mac=>$mac});
				  $mactab->close();
    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub close
{
    my $self = shift;
    #if ($self->{dbh}) { $self->{dbh}->disconnect(); }
    #undef $self->{dbh};
    if ($self->{tabname} eq 'nodelist') {
       undef $self->{nodelist};
    } else {
       $self->{nodelist}->close();
    }
}

#--------------------------------------------------------------------------

=head3 open

    Description: Connect to Database

    Arguments:
           Empty Hash
    Returns:
           Data Base Handle
    Globals:

    Error:

    Example:

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
#UNSUED FUNCTION
#sub open
#{
#    my $self = shift;
#    $self->{dbh} = DBI->connect($self->{connstring}, "", "");
#}

#--------------------------------------------------------------------------

=head3 DESTROY

    Description:  Disconnect from Database

    Arguments:
              Database Handle
    Returns:

    Globals:

    Error:

    Example:

    Comments:
        none

=cut

#--------------------------------------------------------------------------------
sub DESTROY
{
    my $self = shift;
    $self->{dbh} = '';
    undef $self->{dbh};
    #if ($self->{dbh}) { $self->{dbh}->disconnect(); undef $self->{dbh};}
    undef $self->{nodelist};    #Could be circular
}

=head3 getTableList
	Description: Returns a list of the table names in the xCAT database.
=cut
sub getTableList { return keys %xCAT::Schema::tabspec; }


=head3 getTableSchema
	Description: Returns the db schema for the specified table.
	Returns: A reference to a hash that contains the cols, keys, etc. for this table. (See Schema.pm for details.)
=cut
sub getTableSchema { return $xCAT::Schema::tabspec{$_[1]}; }


=head3 getTableList
	Description: Returns a summary description for each table.
	Returns: A reference to a hash.  Each key is the table name.
			Each value is the table description.
=cut
sub getDescriptions {
	my $classname = shift;     # we ignore this because this function is static
	# List each table name and the value for table_desc.
	my $ret = {};
	#my @a = keys %{$xCAT::Schema::tabspec{nodelist}};  print 'a=', @a, "\n";
	foreach my $t (keys %xCAT::Schema::tabspec) { $ret->{$t} = $xCAT::Schema::tabspec{$t}->{table_desc}; }
	return $ret;
}

#--------------------------------------------------------------------------
=head3  isAKey 
    Description:  Checks to see if table field is a table key 

    Arguments:
               Table field 
	       List of keys 
    Returns:
               1= is a key
               0 = not a key 
    Globals:

    Error:

    Example:
              if(isaKey($key_list, $col));

=cut
#--------------------------------------------------------------------------------
sub isAKey 
{
    my ($keys,$col)  = @_;
    my @key_list = @$keys;
    foreach my $key (@key_list)
    {
       if ( $col eq $key) {   # it is a key
         return 1;
       } 
    }
    return 0;
}

#--------------------------------------------------------------------------
=head3   getAutoIncrementColumns
    get a list of column names that are of type "INTEGER AUTO_INCREMENT".

    Returns:
        an array of column names that are auto increment.
=cut
#--------------------------------------------------------------------------------
sub getAutoIncrementColumns {
    my $self=shift;
    my $descr=$xCAT::Schema::tabspec{$self->{tabname}};
    my $types=$descr->{types};
    my @ret=();

    foreach my $col (@{$descr->{cols}})
    {
	if (($types) && ($types->{$col})) {
            if ($types->{$col} =~ /INTEGER AUTO_INCREMENT/) { push(@ret,$col); }
	}
    }
    return @ret;
}


1;

