package App::JESP;

use Moose;

use App::JESP::Plan;

use DBI;
use DBIx::Simple;
use Log::Any qw/$log/;

use File::Spec;

# Settings
## DB Connection attrbutes.
has 'dsn' => ( is => 'ro', isa => 'Str', required => 1 );
has 'username' => ( is => 'ro', isa => 'Maybe[Str]', required => 1);
has 'password' => ( is => 'ro', isa => 'Maybe[Str]', required => 1);
has 'home' => ( is => 'ro', isa => 'Str', required => 1 );
## JESP Attributes
has 'prefix' => ( is => 'ro', isa => 'Str', default => 'jesp_' );

# Operational stuff
has 'get_dbh' => ( is => 'ro', isa => 'CodeRef', default => sub{
                       my ($self) = @_;
                       return sub{
                           return DBI->connect( $self->dsn(), $self->username(), $self->password(),
                                                { RaiseError => 1,
                                                  PrintError => 0,
                                                  AutoCommit => 1
                                              });
                       };
                   });

has 'dbix_simple' => ( is => 'ro', isa => 'DBIx::Simple', lazy_build => 1);
has 'patches_table_name' => ( is => 'ro', isa => 'Str' , lazy_build => 1);
has 'meta_patches' => ( is => 'ro', isa => 'ArrayRef[HashRef]',
                        lazy_build => 1 );


has 'plan' => ( is => 'ro', isa => 'App::JESP::Plan', lazy_build => 1);

sub _build_plan{
    my ($self) = @_;
    my $file = File::Spec->catfile( $self->home(), 'plan.json' );
    unless( -e -r $file ){
        die "File $file does not exists or is not readable\n";
    }
    return App::JESP::Plan->new({ file => $file, jesp => $self });
}

sub _build_dbix_simple{
    my ($self) = @_;
    my $dbh = $self->get_dbh()->();
    my $db =  DBIx::Simple->connect($dbh);
}

sub _build_patches_table_name{
    my ($self) = @_;
    return $self->prefix().'patch';
}

# Building the meta patches, in SQLite compatible format.
sub _build_meta_patches{
    my ($self) = @_;
    return [
        { id => $self->prefix().'meta_zero', sql => 'CREATE TABLE '.$self->patches_table_name().' ( id VARCHAR(512) NOT NULL PRIMARY KEY, applied_datetime TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP );' }
    ];
}

sub install{
    my ($self) = @_;

    # First try to select from $self->patches_table_name
    my $dbh = $self->dbix_simple->dbh();
    my $patches = eval{
        $self->_protect_select(
            sub{ $self->dbix_simple()->query('SELECT '.$dbh->quote_identifier('id').' FROM '.$dbh->quote_identifier($self->patches_table_name)); },
            "CANNOT_SELECT_FROM_META");
    };
    if( my $err = $@ ){
        unless( $err eq "CANNOT_SELECT_FROM_META\n" ){
            $log->critical("Unexpected error from _protect_select. Run again in verbose mode.");
            die $err;
        }
        $log->info("Innitiating meta tables");
        $self->_apply_meta_patch( $self->meta_patches()->[0] );
    }
    $log->info("Uprading meta tables");
    # Select all meta patches and make sure all of mine are applied.
    my $applied_patches = { $self->dbix_simple()
                                ->select( $self->patches_table_name() , [ 'id', 'applied_datetime' ] , { id => { -like => $self->prefix().'meta_%' } } )
                                ->map_hashes('id')
                            };
    foreach my $meta_patch ( @{ $self->meta_patches() } ){
        if( $applied_patches->{$meta_patch->{id}} ){
            $log->debug("Patch ".$meta_patch->{id}." already applied on ".$applied_patches->{$meta_patch->{id}}->{applied_datetime});
            next;
        }
        $self->_apply_meta_patch( $meta_patch );
    }
    $log->info("Done upgrading meta tables");
    return 1;
}

sub deploy{
    my ($self) = @_;

    my $db = $self->dbix_simple();
    my $patches = $self->plan()->patches();

    my $applied_patches_result = $self->_protect_select(
        sub{
            $db->select( $self->patches_table_name() , [ 'id', 'applied_datetime' ] );
        }, "ERROR querying meta schema. Did you forget to run 'install'?");

    my $applied_patches = { $applied_patches_result->map_hashes('id') };

    my $applied = 0;
    foreach my $patch ( @{$patches} ){
        if( my $applied_patch = $applied_patches->{$patch->id()}){
            $log->debug("Patch ".$patch->id()." has already been applied on ".$applied_patch->{applied_datetime});
            next;
        }
        $log->info("Patch ".$patch->id()." not applied yet. Applying it");
        eval{
            $db->begin_work();
            $db->insert( $self->patches_table_name() , { id => $patch->id() } );

            $db->commit();
        };
        if( my $err = $@ ){
            $log->error("Got error $err. ROLLING BACK");
            $db->rollback();
            die "ERROR APPLYING PATCH ".$patch->id().": $err. ABORTING\n";
        };
        $applied++;
    }
    return $applied;
}

# Runs the code to return a DBIx::Simple::Result
# or die with the given error message (for humans)
sub _protect_select{
    my ( $self, $code , $message) = @_;
    my $result = eval{ $code->(); };
    if( my $err = $@ || $result->isa('DBIx::Simple::Dummy')  ){
        $log->debug("Error doing select: ".(  $err || $self->dbix_simple()->error() ) );
        die $message."\n";
    }
    return $result;
}

sub _apply_meta_patch{
    my ($self, $meta_patch) = @_;
    $log->debug("Appliyng meta patch ".$meta_patch->{id});

    my $sql = $meta_patch->{sql};
    my $db = $self->dbix_simple();

    $log->debug("Doing ".$sql);
    $db->begin_work();
    $db->dbh->do( $sql ) or die "Cannot do '$sql':".$db->dbh->errstr()."\n";
    $db->insert( $self->patches_table_name() , { id => $meta_patch->{id} } );
    $db->commit();
}

__PACKAGE__->meta->make_immutable();
1;

__END__

=head1 NAME

App::JESP - Just Enough SQL Patches

=cut

=head1 SYNOPSIS

Use the command line utility:

  jesp --home path/to/jesphome

Or use from your own program (in Perl):

  my $jesp = App::JESP->new({ home => 'path/to/jesphome',
                              dsn => ...,
                              username => ...,
                              password => ...
                            });

  $jsep->install();
  $jesp->deploy();

=cut

=head1 CONFIGURATION

All JESP configuration must live in a JESP home directory.

This home directory must contain a plan.json file, containing the patching
plan for your DB. See plan.json section below for the format of this file.

=head2 plan.json

This file MUST live in your JESP home directory. It has to contain
a json datastructure like this:

  {
    "patches": [
        { "id":"foobartable", "sql": "CREATE TABLE foobar(id INT PRIMARY KEY)"},
        { "id":"foobar_more", "file": "patches/morefoobar.sql" }
    ]
  }

Patches MUST have a unique ID in all the plan, and they can either
contain raw SQL (SQL key), or point to a file of your choice (in the JESP home)
itself containing the SQL.

=head1 COMPATIBILITY

Compatibility of the meta-schema with SQLite, MySQL and PostgreSQL is guaranteed through automated testing.
To see which versions are actually tested, look at the CI build:
L<https://travis-ci.org/jeteve/App-JESP/>

=head1 MOTIVATIONS & DESIGN

Over the years as a developer, I have used at least three ways of managing SQL patches.
The ad-hoc way with a hand-rolled system which is painful to re-implement,
the L<DBIx::Class::Migration> way which I didn't like at all, and more recently
L<App::Sqitch> which I sort of like.

All these systems somehow just manage to do the job, but unless they are very complicated (there
are no limits to hand-rolled complications..) they all fail to provide a sensible
way for a team of developers to work on database schema changes at the same time.

So I decided the world needs yet another SQL patch management system that
does what my team and I really really want.

Here are some design principles this package is attempting to implement:

=over

=item Write your own SQL

No funny SQL generated from code here. By nature, any ORM will always lag behind its
target DBs' features. This means that counting on sofware to generate SQL statement from
your ORM classes will always prevent you from truly using the full power of your DB of choice.

With App::JESP, you have to write your own SQL for your DB, and this is a good thing.

=item No version numbers

App::JESP simply keep track of which ones of your named patches are applied to the DB.
Your DB version is just that: The subset of patches that were applied to it. This participates
in allowing several developers to work on different parts of the DB in parrallel.

=item No fuss patch ordering

The order in which patches are applied is important. But it is not important
to the point of enforcing excatly the same order on every DB the patches are deployed to.
App::JESP applies the named patches in the order it finds them in the plan, only taking
into account the ones that have not been applied yet. This allows developer to work
on their development DB and merge seemlessly patches from other developers.

=item JSON Based

This is the 21st century, and I feel like I shouldn't invent my own file format.
This uses JSON like everything else.

=item Simple but complex things allowed.

You will find no complex feature in App::JESP, and we pledge to keep the meta schema
simple, to allow for easy repairs if things go wrong.

=item Programmable

It's great to have a convenient command line tool to work and deploy patches, but maybe
your development process, or your code layout is a bit different. If you use L<App::JESP>
from Perl, it should be easy to embed and run it seemlessly yourself.

=back

=head1 METHODS

=head2 install

Installs or upgrades the JESP meta tables in the database. This is idem potent.
Note that the JESP meta table(s) will be all prefixed by B<$this->prefix()>.

Returns true on success. Will die on error.

Usage:

  $this->install();

=head2 deploy

Deploys the unapplied patches from the plan in the database and record
the new DB state in the meta schema. Dies if the meta schema is not installed (see install method).

Returns the number of patches applied.

Usage:

  print "Applied ".$this->deploy()." patches";

=head1 DEVELOPMENT

=for html <a href="https://travis-ci.org/jeteve/App-JESP"><img src="https://travis-ci.org/jeteve/App-JESP.svg?branch=master"></a>

=head1 COPYRIGHT

This software is released under the Artistic Licence by Jerome Eteve. Copyright 2016.
A copy of this licence is enclosed in this package.

=cut
