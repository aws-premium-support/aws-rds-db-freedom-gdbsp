SET SCAN            OFF
SET LINESIZE        132
SET SQLBLANKLINES   ON

CREATE OR REPLACE PACKAGE aws_rds_to_s3_pkg
AS
/* ---------------------------------------------------------------------------------------------------------------------------------
File Name:    AWS_S3_PKG.PKB
Author:       Mike Revitt
Date:         11/03/2018
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name       | Description
------------+------------+----------------------------------------------------------------------------------------------------------
30/07/2018  | M Revitt   | Add copy routine to allow files to be copied between Oracle Directories and S3 buckets
13/04/2018  | M Revitt   | Update S3 bucket regions with latest region names
11/03/2018  | M Revitt   | Initial Version
------------+------------+----------------------------------------------------------------------------------------------------------
Function:   To provide an interface between AWS RDS Oracle and AWS S3 Buckets                                                     */

HELP_TEXT   CONSTANT    VARCHAR2(4096) := '
+----------------------------------------------------------------------------------------------------------------------------------+
| The program is devided into two sections                                                                                         |
| o  Routines that are used to setup the environment                                                                               |
|    Package body variables that are set via the setup routine only persist for the duration of the Oracle session.                |
|                                                                                                                                  |
| o  The S3 interface routines, of which there are five S3 commands, one file copy command and one help message.                   |
|    When using the optional prefix with put or copy commands, if the prefix does not exist it will be automatically created       |
|    Removing the last object from a prefix within a bucket will remove the prefix from that bucket.                               |
|                                                                                                                                  |
|    o  S3 Commands                                                                                                                |
|       o   Delete Object       Removes an object from a named bucket, with an optional prefix                                     |
|       o   Get Bucket List     Gets a list of all buckts to which the user has access                                             |
|       o   Get Object List     Gets a list of all objects in a named bucket, with an optional prefix                              |
|       o   Get Object Blob     Gets the contents of an object from a named bucket, with an optional prefix                        |
|       o   Put Object Blob     Writes the contents of an object to a named bucket, with an optional prefix                        |
|                                                                                                                                  |
|    o  Copy Command                                                                                                               |
|       o   Copy File           Copies files between an Oracle directory and an S3 bucket.                                         |
|                               The copy moves the file from the first location to the second location                             |
|                               The command automatically determins of the source is an S3 bucket or Oracle Directory              |
|                               You can optionally provide a prefix, which will only be applied to the S3 bucket                   |
|                                                                                                                                  |
|    o  Help Message                                                                                                               |
|       o   awsHelp             This message                                                                                       |
|       o   Requires                                                                                                               |
|           o    SET SERVEROUTPUT ON size 4096                                                                                     |
|           o    SET LINESIZE 132                                                                                                  |
+----------------------------------------------------------------------------------------------------------------------------------+
';/*
Documenation:
-------------
Oracle Documentation
o   https://oracle-base.com/articles/misc/apex_web_service-consuming-soap-and-rest-web-services

AWS Documenation
o   http://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-authenticatINg-requests.html

Useful Reference Data
o   https://github.com/cmoore-sp/plsql-aws-s3/tree/master
o   http://czak.pl/2015/09/15/s3-rest-api-with-curl.html

Purpose:
--------

Challenges:
-----------
S3 security has been updated to use SHA-2 with AES256 bit encryption, this is much more
sensitive to format and less forgiving of syntactical variances

Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the Software
without restriction, including without limitation the rights to use, copy, modify,
merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

-------------------------------------------------------------------------------------- */
--                              S E C T I O N
--
--                            GLOBAL DATA TYPES
--                            -----------------
TYPE    tBucket
IS      RECORD
(
    bucket_name     VARCHAR2(255),
    creation_date   DATE
);

TYPE    tObject
IS      RECORD
(
    key             VARCHAR2(4000),
    size_bytes      NUMBER,
    last_modified   DATE,
    version_id      VARCHAR2(4000)
);

TYPE    tGrantee
IS      RECORD
(
    grantee_type    VARCHAR2(20),   -- CanonicalUser or Group
    user_id         VARCHAR2(200),  -- for users
    user_name       VARCHAR2(200),  -- for users
    group_uri       VARCHAR2(200),  -- for groups
    permission      VARCHAR2(20)    -- FULL_CONTROL, WRITE, READ_ACP
);

TYPE    BUCKET_TABLE  IS  TABLE   OF  tBucket;
TYPE    BUCKET_LIST   IS  TABLE   OF  tBucket    INDEX   BY  BINARY_INTEGER;
TYPE    OBJECT_LIST   IS  TABLE   OF  tObject    INDEX   BY  BINARY_INTEGER;

AWS_S3_EXCEPTION            NUMBER  := -20600;
AWS_NO_MISSING_EXCEPTION    NUMBER  := -20601;
--------------------------------------------------------------------------------
--                              S E C T I O N
--
--                             GLOBAL VARIABLES
--                             ----------------
--
-- Debug Codes
--------------------------------------------------------------------------------
DEBUG_OFF                   CONSTANT    BINARY_INTEGER  :=  0;  -- No Debug
DEBUG_ON                    CONSTANT    BINARY_INTEGER  :=  1;  -- Shows exposed functions only
DEBUG_CONN                  CONSTANT    BINARY_INTEGER  :=  2;  -- Adds Connection String Data
DEBUG_VERBOSE               CONSTANT    BINARY_INTEGER  :=  3;  -- Full Verbose Mode

-- bucket regions
-- see http://aws.amazon.com/articles/3912?_encoding=UTF8-jiveRedirect=1#s3
-- see http://docs.aws.amazon.com/general/latest/gr/rande.html#s3_region
--------------------------------------------------------------------------------
REGION_ASIA_PACIFIC_SINGAPORE   CONSTANT VARCHAR2(16)   := 'ap-southeast-1';
REGION_ASIA_PACIFIC_SYDNEY      CONSTANT VARCHAR2(16)   := 'ap-southeast-2';
REGION_ASIA_PACIFIC_TOKYO       CONSTANT VARCHAR2(16)   := 'ap-northeast-1';
REGION_EU_IRELAND               CONSTANT VARCHAR2(16)   := 'eu-west-1';
REGION_STH_AMERICA_SAO_PAULO    CONSTANT VARCHAR2(16)   := 'sa-east-1';
REGION_US_EAST_VIRGINIA         CONSTANT VARCHAR2(16)   := 'us-east-1';
REGION_US_STANDARD              CONSTANT VARCHAR2(16)   := 'us-east-1';
REGION_US_WEST_CALIFORNIA       CONSTANT VARCHAR2(16)   := 'us-west-1';
REGION_US_WEST_OREGON           CONSTANT VARCHAR2(16)   := 'us-west-2';

-- The following sites are AWS Version 4 only
REGION_US_EAST_OHIO             CONSTANT VARCHAR2(16)   := 'us-east-2';
REGION_CANADA_CENTRAL_1         CONSTANT VARCHAR2(16)   := 'ca-central-1';
REGION_ASIA_PACIFIC_MUMBAI      CONSTANT VARCHAR2(16)   := 'ap-south-1';
REGION_ASIA_PACIFIC_SEOUL       CONSTANT VARCHAR2(16)   := 'ap-northeast-2';
REGION_ASIA_PACIFIC_OSAKA       CONSTANT VARCHAR2(16)   := 'ap-northeast-3';
REGION_CHINA_BEIJING            CONSTANT VARCHAR2(16)   := 'cn-north-1';
REGION_CHINA_NINGXIA            CONSTANT VARCHAR2(16)   := 'cn-northwest-1';
REGION_EU_FRANKFURT             CONSTANT VARCHAR2(16)   := 'eu-central-1';
REGION_EU_LONDON                CONSTANT VARCHAR2(16)   := 'eu-west-2';
REGION_EU_PARIS                 CONSTANT VARCHAR2(16)   := 'eu-west-3';

--------------------------------------------------------------------------------
--                          S E C T I O N   
--
--                M A N A G E M E N T   S E C T I O N
--
-- These should be kept alphabetized
--------------------------------------------------------------------------------
PROCEDURE   setAwsKeys
            (
                pAwsID          IN      VARCHAR2,
                pAwsKey         IN      VARCHAR2
            );

PROCEDURE   setAwsRegion
            (
                pAwsRegion      IN      VARCHAR2
            );

PROCEDURE   setDebugOff;

PROCEDURE   setDebugOn
            (
                bMode           IN      BINARY_INTEGER  DEFAULT DEBUG_ON
            );

PROCEDURE   setTimeZone
            (
                pTimeZone       IN      VARCHAR2
            );

PROCEDURE   setWalletPassword
            (
                pWalletPwd      IN      VARCHAR2
            );
--------------------------------------------------------------------------------
--                          S E C T I O N
--
--                 P R O G R A M M E   S E C T I O N
--
-- These should be kept alphabetized
--------------------------------------------------------------------------------
PROCEDURE   awsHelp;

PROCEDURE   copyFile
            (
                pSource         IN      VARCHAR2,
                pFileName       IN      VARCHAR2,
                pDestination    IN      VARCHAR2,
                pPrefix         IN      VARCHAR2        DEFAULT NULL
            );

PROCEDURE   deleteObject
            (
                pBucket         IN      VARCHAR2,
                pObjectName     IN      VARCHAR2,
                pPrefix         IN      VARCHAR2        DEFAULT NULL
            );

FUNCTION    getBucketList
    RETURN  BUCKET_LIST;

FUNCTION    getObjectBlob
            (
                pBucket         IN      VARCHAR2,
                pObjectName     IN      VARCHAR2,
                pPrefix         IN      VARCHAR2        DEFAULT NULL
            )
    RETURN  BLOB;

PROCEDURE   getObjectList
            (
                pBucket         IN      VARCHAR2,
                pPrefix         IN      VARCHAR2        DEFAULT NULL,
                pObjectName     IN      VARCHAR2        DEFAULT NULL,
                pFilesRemaining     OUT BOOLEAN,
                pObjectList         OUT OBJECT_LIST
            );

PROCEDURE   putObjectBlob
            (
                pBucket         IN      VARCHAR2,
                pBlob           IN      BLOB,
                pObjectKey      IN      VARCHAR2,
                pPrefix         IN      VARCHAR2        DEFAULT NULL
            );

end aws_rds_to_s3_pkg;
/

SET SCAN            ON
SET SQLBLANKLINES   OFF
