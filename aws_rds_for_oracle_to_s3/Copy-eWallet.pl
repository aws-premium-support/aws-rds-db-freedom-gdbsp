#!/usr/bin/perl
# File Name:    Copy-eWallet.pl
# Author:       Mike Revitt
# Date:         08/08/2018
#
# DESCRIPTION:
#   copies eWallet.p12 into SSL_WALLET_DIR.
#
#   See usage for details.
#
#   This program requires Perl version 5.010, plus the
#   DBI and DBD::Oracle libraries.  See www.cpan.org for details.
#
# ----------------------------------------------------------------------------------------------------------------------------------
# Revision History    Push Down List
# ----------------------------------------------------------------------------------------------------------------------------------
# Date        | Name       | Description
# ------------+------------+--------------------------------------------------------------------------------------------------------
# 10.08/2018  | M Revitt   | Added comments
# 08/08/2018  | M Revitt   | Initial Version
# ------------+------------+--------------------------------------------------------------------------------------------------------
#
# Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify,
# merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

use DBI;
use Getopt::Long qw(GetOptions);
use 5.010;
use warnings;

## Parameters
$| = 1; # set stdout to flush

## Global Variables
$db->{LongReadLen}=10240;  # Make sure buffer is big enough for eWallet.p12 currently 10KB

# ----------------------------------------------------------------------------------------------------------------------------------
# Routine Name: getInputs
#
# Description:  Reads the command line inputs via the Get:opt function GetOptions
#
# Requirements: Requires use Getopt::Long qw(GetOptions);
#
# ----------------------------------------------------------------------------------------------------------------------------------
sub getInputs
{
    GetOptions
    (
    'USER=s'        => \$dbUser,
    'PASSWD=s'      => \$dbPasswd,
    'TNS=s'         => \$dbName,
    'LDIR=s'        => \$osDir,
    )
    or die "Usage: $0 --from NAME\n ";
    
    if( $dbUser and $dbPasswd and $dbName and $osDir )
    {
        print "User options for fileupload run:\n";
        print "--USER $dbUser --PASSWD <hidden> --TNS $dbName --LDIR $osDir\n";
    }
    else
    {
        usage("\nYou have not specified all of the inputs required\n\n");
    }
}
# ----------------------------------------------------------------------------------------------------------------------------------
# Routine Name: usage
#
# Description:  Prints out a usage message if any of the options are missing or invalid
#
# Requirements: Requires use warnings;
#
# ----------------------------------------------------------------------------------------------------------------------------------
sub usage {
    my $message = $_[0];
    my $command = $0;

    if (defined $message && length $message)
    {
      $message .= "\n"
       unless $message =~ /\n$/;
    }
    $command =~ s#^.*/##;
    print( $message, "usage: $command --USER <DB Username> --PASSWD <DB Password> --TNS <TNS Connect String> --LDIR <Local Directory>\n\n" );
    print( "e.g.: ./$command --USER mike --PASSWD password --TNS file-test --LDIR /home/oracle\n\n" );
    exit(2);
}
# ----------------------------------------------------------------------------------------------------------------------------------
# Routine Name: connectDb
#
# Description:  Connects to the Oracle Database using the database username and password, plus the TNS connect string
#
# Requirements: Requires use DBI;
#               Also requires that there is a valid Oracle Instant Client environment and the TNS_ADMIN is setup and that there
#               is a suitable entry for the database to which we are connecting
#
# Parameters:   dbName      A valid entry in tnsnames.ora
#               dbUser      The Oracle username that we will use
#               dbPasswd    The Oracle password for the user
#
# ----------------------------------------------------------------------------------------------------------------------------------
sub connectDb
{
    my $dataSource = "dbi:Oracle:${dbName}"; # interface:driver:db_name
    
    $db = DBI->connect($dataSource, $dbUser, $dbPasswd);
    $db ||     die "Error connecting to db: $DBI::errstr\n";
}
# ----------------------------------------------------------------------------------------------------------------------------------
# Routine Name: putWallet
#
# Description:  Creates a database package variable that holds the pointer to the UTL_FILE Handle
#               This pacakge variable is then used in a SQL loop to copy the Wallet into the file in chunks until the entire contents
#               have been copied.
#
# Requirements: Requires that the database user has write on the ORACLE DIRECTORY
#
# Parameters:   osDir       The full path of the Operating System Directory
#
# ----------------------------------------------------------------------------------------------------------------------------------
sub putWallet
{
    my $rawData;
    my $fh;
    my $stmt;
    my $fname      = 'ewallet.p12';
    my $fileSource = "$osDir/$fname";
    my %attrib     = ('ora_type','24'); # Oracle type id for blobs
    my $val        = 1;
    my $chunk      = 10240;             # Make sure buffer is big enough for eWallet.p12 currently 10KB and should match $db
    my $sqlExecute = "DECLARE \
                        ftOutputFile UTL_FILE.FILE_TYPE; \
                      BEGIN \
                        ftOutputFile := UTL_FILE.FOPEN( 'SSL_WALLET_DIR', '$fname', 'wb' );    \
                        UTL_FILE.PUT_RAW( ftOutputFile, :rawData, TRUE );   \
                        UTL_FILE.FFLUSH(  ftOutputFile );                   \
                        UTL_FILE.FCLOSE(  ftOutputFile );                   \
                      END;";
    
    open $fh, '<', $fileSource or die "open: $!\n";
    binmode($fh);
    read ($fh, $rawData, $chunk);
    close $fh or die "close: $!\n";

    $stmt = $db->prepare($sqlExecute) || die "\nPrepare error: $DBI::err .... $DBI::errstr\n";
    $stmt->bind_param(":rawData", $rawData , \%attrib);
    $stmt->execute() || die "\nExecute error: $DBI::err .... $DBI::errstr\n";
}
# ----------------------------------------------------------------------------------------------------------------------------------
# Routine Name: checkUploads
#
# Description:  Reads the contents of the Oracle Directory and lists out all files in the directory
#
# Requirements: Requires that the database user select on the ORACLE DIRECTORY
#
# Parameters:   oraDir      The name for the ORACLE DIRECTORY
#               fname       The filename to be copied
#
# ----------------------------------------------------------------------------------------------------------------------------------
sub checkUploads
{
    my $sqlCheck = "SELECT * FROM table(rdsadmin.rds_file_util.listdir('SSL_WALLET_DIR')) order by 1";
    my $stmt = $db->prepare($sqlCheck) || die "\nPrepare error: $DBI::err .... $DBI::errstr\n";
    
    $stmt->execute() || die "\nExecute error: $DBI::err .... $DBI::errstr\n";
    
    print "Files uploaded sucessfully\n";
    while (my @data = $stmt->fetchrow_array())
    {
        print "$data[0]\tsize: $data[2] bytes\n";
    }
}
# ----------------------------------------------------------------------------------------------------------------------------------
# Routine Name: Main
#
# Description:  Runs the program
#
# ----------------------------------------------------------------------------------------------------------------------------------
getInputs;
connectDb;
putWallet;
checkUploads;
