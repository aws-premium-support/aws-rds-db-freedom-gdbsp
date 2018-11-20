SET SCAN OFF

CREATE OR REPLACE PACKAGE BODY aws_rds_to_s3_pkg
AS
/* ---------------------------------------------------------------------------------------------------------------------------------
File Name:    aws_rds_to_s3_pkg.PKB
Author:       Mike Revitt
Date:         11/03/2018
------------------------------------------------------------------------------------------------------------------------------------
Revision History    Push Down List
------------------------------------------------------------------------------------------------------------------------------------
Date        | Name       | Description
------------+------------+----------------------------------------------------------------------------------------------------------
07/08/2018  | M Revitt   | Added DBMS_LOB.CLOSE in bGetOracleFile
06/08/2018  | M Revitt   | Add code to deal with zero byte file copies and to trap errors that occur when getting a file from S3
30/07/2018  | M Revitt   | Add copy routine to allow files to be copied between Oracle Directoris and S3 buckets
11/03/2018  | M Revitt   | Initial version
------------+------------+----------------------------------------------------------------------------------------------------------
Function:   To provide an interface between AWS RDS Oracle and AWS S3 Buckets
------------------------------------------------------------------------------------------------------------------------------------
Documenation:
-------------
Oracle Documentation
o   https://docs.oracle.com/database/apex-5.1/AEAPI/toc.htm

AWS Documenation
o   http://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-authenticatINg-requests.html

Useful Reference Data
o   https://oracle-base.com/articles/misc/apex_web_service-consuming-soap-and-rest-web-services
o   https://github.com/cmoore-sp/plsql-aws-s3/tree/master
o   http://czak.pl/2015/09/15/s3-rest-api-with-curl.html


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
--                            PRIVATE VARIABLES
--                            -----------------
--
-- All of the values in the first section, with the exception of the Wallet Path,
-- can be overritten by the set routines in this program as required at runtime.
--
-- These over-rights will only persist for the current SQL*Plus session
-- *******************************************************************************************************
-- ****************** THIS SECTION CONTAINS THE ONLY VAIABLES THAT ARE USER UPDATEABLE *******************
--                                                                                                       *
-- You need to change the Access and Secret KeyS to suit your environment                                *
-- The WALLET_PATH must be retrieved when the WALLET directory is created and updated here               *
---------------------------------------------------------------------------------------------------------*
bDebug                                  BINARY_INTEGER  :=  DEBUG_OFF;                                 --*
                                                                                                       --*
AWS_ACCESS_KEY                          VARCHAR2(20)    := 'AKIAIOSFODNN7EXAMPLE';                     --*
AWS_REGION                              VARCHAR2(16)    := 'eu-west-2';                                --*
AWS_SECRET_KEY                          VARCHAR2(64)    := 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'; --*
TIME_ZONE                               VARCHAR2(64)    := 'UTC';                                      --*
WALLET_PASSWORD                         VARCHAR2(32)    := 'S3-Oracle';                                --*
WALLET_PATH                 CONSTANT    VARCHAR2(32)    := 'file:/rdsdbdata/userdirs/02/';             --*
-- *******************************************************************************************************

-- These are all constants that are required by the Version 4 security protocol of AWS S3
--------------------------------------------------------------------------------
AWS_AUTH_MECHANISM          CONSTANT    VARCHAR2(16)    := 'AWS4-HMAC-SHA256';
AWS_NAMESPACE_S3            CONSTANT    VARCHAR2(128)   := 'http://s3.amazonaws.com/doc/2006-03-01/';
AWS_NAMESPACE_S3_FULL       CONSTANT    VARCHAR2(128)   := 'xmlns="' || AWS_NAMESPACE_S3 || '"';
AWS_REQUEST                 CONSTANT    VARCHAR2(16)    := 'aws4_request';
AWS_SECRET_KEY_PREFIX       CONSTANT    VARCHAR2(4)     := 'AWS4';
AWS_SERVICE                 CONSTANT    VARCHAR2(2)     := 's3';
DATE_FORMAT_URL             CONSTANT    VARCHAR2(8)     := 'YYYYMMDD';
DATE_FORMAT_XML             CONSTANT    VARCHAR2(32)    := 'YYYY-MM-DD"T"HH24:MI:SS".000Z"';
ISO8601_DATE_FORMAT         CONSTANT    VARCHAR2(32)    := 'YYYYMMDD"T"HH24MISS"Z"';
ISO8601_DATE_STR_LEN        CONSTANT    VARCHAR2(30)    :=  32;
UNICODE_UTF8                CONSTANT    VARCHAR2(8)     := 'AL32UTF8';
UNICODE_AL32UTF8_ID         CONSTANT    VARCHAR2(3)     :=  873;
URL_DATE_STR_LEN            CONSTANT    VARCHAR2(30)    :=  8;
XML_DATE_STR_LEN            CONSTANT    VARCHAR2(30)    :=  32;

-- Characters used in URLs and string constructs
--------------------------------------------------------------------------------
AMPERSAND                   CONSTANT    VARCHAR2(1)     :=  CHR(38);
CARRIAGE_RETURN             CONSTANT    VARCHAR2(1)     :=  CHR(13);
LINE_FEED                   CONSTANT    VARCHAR2(1)     :=  CHR(10);
NON_HIERARCHICAL_SLASH      CONSTANT    VARCHAR2(3)     := '%2F';
SLASH                       CONSTANT    VARCHAR2(1)     := '/';
TAB_CHARACTER               CONSTANT    VARCHAR2(1)     :=  CHR(9);
TWO_TAB_CHARACTERS          CONSTANT    VARCHAR2(2)     :=  CHR(9) || CHR(9);
URL_AMPERSAND               CONSTANT    VARCHAR2(3)     := '%26';
URL_QUERY_STRING            CONSTANT    VARCHAR2(1)     := '?';

-- Delimiters and terminators used in URLs and string constructs
--------------------------------------------------------------------------------
AWS_V4_HEADER_DELIMITER     CONSTANT    VARCHAR2(1)     := ';';
CMD_TERMINATER              CONSTANT    VARCHAR2(1)     := ':';
COMMA_DELIMITER             CONSTANT    VARCHAR2(1)     := ',';
S3_BUCKET_DELIMITER         CONSTANT    VARCHAR2(4)     := '.s3.';
SPACE_DELIMITER             CONSTANT    VARCHAR2(1)     := ' ';

-- AWS S3 Version 4 API calls and string constructs
--------------------------------------------------------------------------------
AWS_V4_CONTENT              CONSTANT    VARCHAR2(20)    := 'x-amz-content-sha256';
AWS_V4_CONTENT_HEADER       CONSTANT    VARCHAR2(21)    :=  AWS_V4_CONTENT  || CMD_TERMINATER;
AWS_V4_CONTENT_LENGTH       CONSTANT    VARCHAR2(14)    := 'Content-Length';
AWS_V4_CONTENT_TYPE         CONSTANT    VARCHAR2(14)    := 'Content-Type';
AWS_V4_DATE                 CONSTANT    VARCHAR2(10)    := 'x-amz-date';
AWS_V4_DATE_HEADER          CONSTANT    VARCHAR2(11)    :=  AWS_V4_DATE     || CMD_TERMINATER;
AWS_V4_MIME_TYPE            CONSTANT    VARCHAR2(24)    := 'application/octet-stream';
AWS_V4_REQUEST_DOMAIN       CONSTANT    VARCHAR2(16)    := '/s3/aws4_request';
SOURCE_IS_BUCKET            CONSTANT    VARCHAR2(32)    := 'Source Location is an S3 Bucket';
HOST                        CONSTANT    VARCHAR2(4)     := 'host';
HOST_CMD                    CONSTANT    VARCHAR2(5)     :=  HOST            || CMD_TERMINATER;
HTTP_AUTHORISATION          CONSTANT    VARCHAR2(13)    := 'Authorization';
HTTP_CREDENTIAL_REQ         CONSTANT    VARCHAR2(11)    := 'Credential=';
HTTP_DELETE_METHOD          CONSTANT    VARCHAR2(6)     := 'DELETE';
HTTP_GET_METHOD             CONSTANT    VARCHAR2(3)     := 'GET';
HTTP_HEAD_METHOD            CONSTANT    VARCHAR2(4)     := 'HEAD';
HTTP_POST_METHOD            CONSTANT    VARCHAR2(4)     := 'POST';
HTTP_PUT_METHOD             CONSTANT    VARCHAR2(3)     := 'PUT';
HTTP_SIGNATURE_REQ          CONSTANT    VARCHAR2(10)    := 'Signature=';
HTTP_SIGNED_HEADER_REQ      CONSTANT    VARCHAR2(14)    := 'SignedHeaders=';
HTTPS_CMD                   CONSTANT    VARCHAR2(8)     := 'https://';
US_OTHER_REGIONS_DOMAIN     CONSTANT    VARCHAR2(14)    := '.amazonaws.com';
US_STANDARD_REGION_DOMAIN   CONSTANT    VARCHAR2(16)    := 's3.amazonaws.com';
US_STANDARD_REGION_URL      CONSTANT    VARCHAR2(25)    :=  HTTPS_CMD || US_STANDARD_REGION_DOMAIN || SLASH;

-- HTTP API Error strings and commands to extract the error messages
--------------------------------------------------------------------------------
XML_BUCKET_NAME             CONSTANT    VARCHAR2(6)     := '*/Name';
XML_CREATION_DATE           CONSTANT    VARCHAR2(14)    := '*/CreationDate';
XML_ERROR_MESSAGE           CONSTANT    VARCHAR2(512)   := '/Error/Message/text()'; -- Needs to be big enough to contain the entire message
XML_ERROR_STRING            CONSTANT    VARCHAR2(8)     := '/Error';
XML_HEADER                  CONSTANT    VARCHAR2(38)    := '<?xml version="1.0" encoding="UTF-8"?>';
XML_LAST_MODIFIED           CONSTANT    VARCHAR2(14)    := '*/LastModified';
XML_LIST_ALL_BUCKETS        CONSTANT    VARCHAR2(39)    := '//ListAllMyBucketsResult/Buckets/Bucket';
XML_LIST_BUCKET_CONTENTS    CONSTANT    VARCHAR2(27)    := '//ListBucketResult/Contents';
XML_LIST_TRUNCATED          CONSTANT    VARCHAR2(37)    := '//ListBucketResult/IsTruncated/text()';
XML_KEY                     CONSTANT    VARCHAR2(5)     := '*/Key';
XML_SIZE                    CONSTANT    VARCHAR2(6)     := '*/Size';
XML_TRUE                    CONSTANT    VARCHAR2(4)     := 'true';


-- UTL_FILE variables and commands
--------------------------------------------------------------------------------
MAX_UTL_FILE_WRITE_SIZE     CONSTANT    BINARY_INTEGER  :=  32767;
UTL_FILE_WRITE_BYTE_MODE    CONSTANT    VARCHAR2(2)     := 'wb';
EMPTY_FILE                  CONSTANT    BINARY_INTEGER  := 0;

-- LOADBLOBFROMFILE variables and commands
--------------------------------------------------------------------------------
SRC_START_OFFSET            CONSTANT    BINARY_INTEGER  :=  1;
DEST_START_OFFSET           CONSTANT    BINARY_INTEGER  :=  1;

-- This is the SHA256 HASH of a empty string. It is used WHEN the request is null
--------------------------------------------------------------------------------
NULL_SHA256__HASH                       VARCHAR2(100)   := 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

--------------------------------------------------------------------------------
--                    D E C L A R A T I O N   S E C T I O N
--
--                     PRIVARTE FUNCTIONS AND PROCEDURES
--                     ---------------------------------
--
-- These should be kept alphabetized within types
--------------------------------------------------------------------------------
FUNCTION    bGetOracleFile
            (
                pDirectoryName  IN      VARCHAR2,
                pFileName       IN      VARCHAR2
            )
    RETURN  BLOB;

FUNCTION    bMakeRestRequest
            (
                pDateString     IN      VARCHAR2,
                pSignature      IN      VARCHAR2,
                pPayloadHash    IN      VARCHAR2,
                pISO_8601Date   IN      VARCHAR2,
                pURL            IN      VARCHAR2,
                pHttpMethod     IN      VARCHAR2
            )
    RETURN  BLOB;

FUNCTION    cMakeRestRequest
            (
                pDateString     IN      VARCHAR2,
                pSignature      IN      VARCHAR2,
                pPayloadHash    IN      VARCHAR2,
                pISO_8601Date   IN      VARCHAR2,
                pURL            IN      VARCHAR2,
                pHttpMethod     IN      VARCHAR2,
                pBlob           IN      BLOB        DEFAULT NULL
            )
    RETURN  CLOB;

FUNCTION    vcAwsV4CryptoHash
            (
                pString         IN      VARCHAR2
            )
    RETURN  VARCHAR2;

FUNCTION    vcAwsV4CryptoHash
            (
                pBlob           IN      BLOB
            )
    RETURN  VARCHAR2;

FUNCTION    vcAwsV4SignedKey
            (
                pStringToSign   IN      VARCHAR2,
                pDate           IN      DATE
            )
    RETURN  VARCHAR2;

FUNCTION    vcCreateStringToSign
            (
                pStringToSign   IN      VARCHAR2,
                pDate           IN      DATE
            )
    RETURN  VARCHAR2;

FUNCTION    vcEncodeUrlAmpersand
            (
                pURL            IN      VARCHAR2
            )
    RETURN  VARCHAR2;

FUNCTION    vcGetCanonicalRequest
            (
                pBucket             IN      VARCHAR2,
                pHttpMethod         IN      VARCHAR2,
                pCanonicalUri       IN      VARCHAR2,
                pQueryString        IN      VARCHAR2    DEFAULT NULL,
                pDate               IN      DATE,
                pPayloadHash        IN      VARCHAR2,
                pCanonicalRequest       OUT VARCHAR2,
                pURL                    OUT VARCHAR2
            )
    RETURN  VARCHAR2;

FUNCTION    vcPrepareAwsData
            (
                pBucket             IN      VARCHAR2,
                pHttpMethod         IN      VARCHAR2,
                pCanonicalUri       IN      VARCHAR2,
                pQueryString        IN      VARCHAR2    DEFAULT NULL,
                pDate               IN      DATE,
                pPayloadHash        IN      VARCHAR2,
                pURL                   OUT  VARCHAR2
            )
    RETURN  VARCHAR2;

FUNCTION    vcReturnISO_8601_Date
            (
                pDate           IN       TIMESTAMP,
                pTimezone       IN      VARCHAR2
            )
    RETURN  VARCHAR2;

FUNCTION    vcSignString
            (
                pStringToSign   IN      VARCHAR2,
                pDate           IN      DATE
            )
    RETURN  VARCHAR2;

PROCEDURE   vCheckForErrorsB
            (
                pBlob   IN  BLOB
            );

PROCEDURE   vCheckForErrors
            (
                pClob           IN      CLOB
            );

PROCEDURE   vCheckForErrors
            (
                pXMLString      IN      XMLTYPE
            );

PROCEDURE   vPrepareRestHeader
            (
                pDateString     IN      VARCHAR2,
                pSignature      IN      VARCHAR2,
                pPayloadHash    IN      VARCHAR2,
                pISO_8601Date   IN      VARCHAR2,
                pLength         IN      BINARY_INTEGER  DEFAULT 0
            );

PROCEDURE   vPutOracleFile
            (
                pDirectoryName  IN      VARCHAR2,
                pBlob           IN      BLOB,
                pFileName       IN      VARCHAR2
            );

PROCEDURE   vValidateHttpMethod
            (
                pHttpMethod     IN  VARCHAR2,
                pProcedure      IN  VARCHAR2
            );

--------------------------------------------------------------------------------
--                     E X E C U T I O N   S E C T I O N
--
--                     PRIVATE FUNCTIONS AND PROCEDURES
--                     --------------------------------
--
-- These should be kept alphabetized within types
--------------------------------------------------------------------------------
FUNCTION    bGetOracleFile
            (
                pDirectoryName  IN      VARCHAR2,
                pFileName       IN      VARCHAR2
            )
    RETURN  BLOB
/*  ----------------------------------------------------------------------------
* Routine Name: bGetOracleFile
*
* Description:  Returns the contents of a specific file as a BLOB
*
* Note:         Now copes with zero byte files, although not sure why someone
*               would want to copy a zero byte file
*
* Arguments:    IN      pDirectoryName  The name of the Oracle Directory
*                                       continaining the file
*               IN      pFileName       The name of the file to be retrieved
*
* Returns:              blob            The contents of the file
----------------------------------------------------------------------------- */
AS
    bExists         BOOLEAN;
    bBlob           BLOB;
    iFileLength     BINARY_INTEGER;
    iBlockSize      BINARY_INTEGER;
    iSrcOffset      BINARY_INTEGER  := SRC_START_OFFSET;
    iDestOffset     BINARY_INTEGER  := DEST_START_OFFSET;
    bFileLocation   BFILE;

BEGIN
    IF bDebug > DEBUG_OFF
    THEN
        DBMS_OUTPUT.PUT_LINE('>>>');
        DBMS_OUTPUT.PUT_LINE('================================================================================' );
        DBMS_OUTPUT.PUT_LINE('bGetOracleFile' );
        DBMS_OUTPUT.PUT_LINE('Directory Name: -' || pDirectoryName );
        DBMS_OUTPUT.PUT_LINE('File Name: -     ' || pFileName );
    END IF;

    UTL_FILE.FGETATTR
    (
        pDirectoryName,
        pFileName,
        bExists,
        iFileLength,
        iBlockSize
    );

    IF TRUE = bExists
    THEN
        bFileLocation := BFILENAME( pDirectoryName, pFileName );
        DBMS_LOB.CREATETEMPORARY( bBlob, TRUE );

        IF iFileLength > 0
        THEN
            DBMS_LOB.OPEN( bFileLocation, DBMS_LOB.LOB_READONLY );
            DBMS_LOB.LOADBLOBFROMFILE
            (
                dest_lob    =>  bBlob,
                src_bfile   =>  bFileLocation,
                amount      =>  DBMS_LOB.LOBMAXSIZE,
                dest_offset =>  iDestOffset,
                src_offset  =>  iSrcOffset
            );
            DBMS_LOB.CLOSE( bFileLocation );
        END IF;
    ELSE
        RAISE_APPLICATION_ERROR
        (
             AWS_NO_MISSING_EXCEPTION,
            'File -:' ||  pFileName || ':- does not exist in -:' || pDirectoryName || ':-'
        );
    END IF;

    IF bDebug > DEBUG_OFF
    THEN
        DBMS_OUTPUT.PUT_LINE('<<<');
    END IF;

    RETURN bBlob;

END bGetOracleFile;
--------------------------------------------------------------------------------
FUNCTION    bMakeRestRequest
            (
                pDateString     IN      VARCHAR2,
                pSignature      IN      VARCHAR2,
                pPayloadHash    IN      VARCHAR2,
                pISO_8601Date   IN      VARCHAR2,
                pURL            IN      VARCHAR2,
                pHttpMethod     IN      VARCHAR2
            )
    RETURN  BLOB
/*  ----------------------------------------------------------------------------
* Routine Name: bMakeRestRequest
*
* Description:  This is the heart of the programme along with the prepare header routines,
*               This function makes the REST Request and return a BLOB.
*
*               Note that the CLOB needs to be examined for errors.
*               http://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
*
* Arguments:    IN      pDateString
*               IN      pSignature
*               IN      pPayloadHash
*               IN      pISO_8601Date
*               IN      pURL
*               IN      pHttpMethod
*
* Returns:              lBlob           Any execution messages
----------------------------------------------------------------------------- */
AS
    lBlob       BLOB;
    XMLString   XMLTYPE;

BEGIN

    vPrepareRestHeader
    (
        pDateString,
        pSignature,
        pPayloadHash,
        pISO_8601Date
    );

    IF bDebug > DEBUG_ON
    THEN
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('========================================================================' );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('bMakeRestRequest' );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('URL: -                ' || pURL );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('HTTP Method: -        ' || pHttpMethod );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('Wallet Path: -        ' || WALLET_PATH );
    END IF;

    IF bDebug = DEBUG_VERBOSE
    THEN
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('Wallet Password: -    ' || WALLET_PASSWORD );
    END IF;

    lBlob   :=  APEX_WEB_SERVICE.MAKE_REST_REQUEST_B
                (
                    p_URL           => pURL,
                    p_HTTP_METHOD   => pHttpMethod,
                    p_wallet_path   => WALLET_PATH,
                    p_wallet_pwd    => WALLET_PASSWORD
                );

    vCheckForErrorsB( lBlob );

    IF bDebug > DEBUG_ON
    THEN
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('Bytes Returned: -     ' || DBMS_LOB.GETLENGTH( lBlob ));
    END IF;

    RETURN lBlob;
END bMakeRestRequest;
--------------------------------------------------------------------------------
FUNCTION    cMakeRestRequest
            (
                pDateString     IN      VARCHAR2,
                pSignature      IN      VARCHAR2,
                pPayloadHash    IN      VARCHAR2,
                pISO_8601Date   IN      VARCHAR2,
                pURL            IN      VARCHAR2,
                pHttpMethod     IN      VARCHAR2,
                pBlob           IN      BLOB        DEFAULT NULL
            )
    RETURN  CLOB
/*  ----------------------------------------------------------------------------
* Routine Name: cMakeRestRequest
*
* Description:  This is the heart of the programme along with the prepare header routines,
*               This function makes the REST Request and return a CLOB.
*
*               Note that the CLOB needs to be examined for errors.
*               http://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
*
* Arguments:    IN      pDateString
*               IN      pSignature
*               IN      pPayloadHash
*               IN      pISO_8601Date
*               IN      pURL
*               IN      pHttpMethod
*
* Returns:              lClob           Any execution messages
----------------------------------------------------------------------------- */
AS
    lClob           CLOB;
    bContentLength  BINARY_INTEGER;

BEGIN

    bContentLength      := DBMS_LOB.GETLENGTH( pBlob );

    vPrepareRestHeader
    (
        pDateString,
        pSignature,
        pPayloadHash,
        pISO_8601Date,
        bContentLength
    );

    IF bDebug > DEBUG_ON
    THEN
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('========================================================================' );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('cMakeRestRequest' );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('URL: -                ' || pURL );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('HTTP Method: -        ' || pHttpMethod );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('Wallet Path: -        ' || WALLET_PATH );
    END IF;

    IF bDebug = DEBUG_VERBOSE
    THEN
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('Wallet Password: -    ' || WALLET_PASSWORD );
    END IF;

    lClob   :=  APEX_WEB_SERVICE.MAKE_REST_REQUEST
                (
                    p_URL           => pURL,
                    p_HTTP_METHOD   => pHttpMethod,
                    p_wallet_path   => WALLET_PATH,
                    p_wallet_pwd    => WALLET_PASSWORD,
                    p_body_blob     => pBlob
                );

    vCheckForErrors( lClob );

    IF bDebug > DEBUG_ON
    THEN
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('Return String: -      ' || SUBSTR( lClob, 1, 512 ));
    END IF;

    RETURN lClob;
END cMakeRestRequest;
--------------------------------------------------------------------------------
FUNCTION    vcAwsV4CryptoHash
            (
                pString     IN  VARCHAR2
            )
    RETURN  VARCHAR2
/*  ----------------------------------------------------------------------------
* Routine Name: vcAwsV4CryptoHash
*
* Description:  Hashes the string using the latest SH256 method
*               AWS requires that the hash is in lower case
*
* Arguments:    IN      pString         The string to be hashed
*
* Returns:              szReturn        the AWS4 escape value
----------------------------------------------------------------------------- */
AS
    szReturn    VARCHAR2(2000);
    rHash       RAW(2000);
    rSource     RAW(2000);

BEGIN
    rSource     := UTL_I18N.STRING_TO_RAW( pString, UNICODE_UTF8 );
    rHash       := DBMS_CRYPTO.HASH
                   (
                        src => rSource,
                        typ => DBMS_CRYPTO.HASH_SH256
                   );

    szReturn := LOWER( RAWTOHEX( rHash ));

    RETURN szReturn;

END vcAwsV4CryptoHash;
--------------------------------------------------------------------------------
FUNCTION    vcAwsV4CryptoHash
            (
                pBlob  IN BLOB
            )
    RETURN  VARCHAR2
/*  ----------------------------------------------------------------------------
* Routine Name: vcAwsV4CryptoHash
*
* Description:  Hashes the blob using the latest SH256 method
*               AWS requires that the hash is in lower case
*
* Arguments:    IN      pBlob           The blob to be hashed
*
* Returns:              szReturn        The AWS4 escape value
----------------------------------------------------------------------------- */
AS
    szReturn    VARCHAR2(2000);
    rHash       RAW(2000);

BEGIN

    rHash :=    DBMS_CRYPTO.HASH
                (
                    src => pBlob,
                    typ => DBMS_CRYPTO.HASH_SH256
                );

    szReturn := LOWER( RAWTOHEX( rHash ));

    RETURN szReturn;

END vcAwsV4CryptoHash;
--------------------------------------------------------------------------------
FUNCTION    vcAwsV4SignedKey
            (
                pStringToSign   VARCHAR2,
                pDate           DATE
            )
    RETURN  VARCHAR2
/*  ----------------------------------------------------------------------------
* Routine Name: vcAwsV4SignedKey
*
* Description:  Follows the guidence of the AWS Signature Version 4 documentation
*               http://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-authenticating-requests.html
*               In accordance with the documentation, the String To Sign is provided
*               to the function and the date is provided so that debugging against
*               known standards is possible.
*               Hashes the string using the latest SH256 method
*               AWS requires that the hash is in lower case
*
* Arguments:    IN      pStringToSign   The string to be signed
*               IN      pDate           The current date
*
* Returns:              szReturn        The signed value
----------------------------------------------------------------------------- */
AS
    szReturn                VARCHAR2(2000);
    vcDateString            VARCHAR2(8);
    rKeyBytesRaw            RAW(2000);
    rSource                 RAW(2000);
    rDateKey                RAW(2000);
    rDateRegionKey          RAW(2000);
    rDateRegionServiceKey   RAW(2000);
    rSigningKey             RAW(2000);
    rSignature              RAW(2000);
    l_date                      date;

BEGIN

    vcDateString := TO_CHAR( pDate, DATE_FORMAT_URL );

    rKeyBytesRaw    := UTL_I18N.STRING_TO_RAW( AWS_SECRET_KEY_PREFIX || AWS_SECRET_KEY, UNICODE_UTF8 );
    rSource         := UTL_I18N.STRING_TO_RAW( vcDateString,                            UNICODE_UTF8 );

    rDateKey    :=  DBMS_CRYPTO.MAC
                    (
                        src => rSource,
                        typ => DBMS_CRYPTO.HMAC_SH256,
                        key => rKeyBytesRaw
                    );

    IF bDebug = DEBUG_VERBOSE
    THEN
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('================================================================' );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('vcAwsV4SignedKey.DBMS_CRYPTO.MAC AWS Key' );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('AWS_SECRET_KEY:-        ' || AWS_SECRET_KEY );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('AWS_SECRET_KEY_PREFIX:- ' || AWS_SECRET_KEY_PREFIX );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('rKeyBytesRaw:-          ' || rKeyBytesRaw );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('vcDateString:-          ' || vcDateString );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('rSource:-               ' || rSource );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('rDateKey:-              ' || rDateKey );
    END IF;

    rSource          := UTL_I18N.STRING_TO_RAW( AWS_REGION, UNICODE_UTF8 );

    rDateRegionKey  :=  DBMS_CRYPTO.MAC
                        (
                            src => rSource,
                            typ => DBMS_CRYPTO.HMAC_SH256,
                            key => rDateKey
                        );

    IF bDebug = DEBUG_VERBOSE
    THEN
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('================================================================' );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('vcAwsV4SignedKey.DBMS_CRYPTO.MAC AWS Region' );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('AWS Region:-     ' || AWS_REGION );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('rSource:-        ' || rSource );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('rDateRegionKey:- ' || rDateRegionKey );
    END IF;

    rSource  := UTL_I18N.STRING_TO_RAW( AWS_SERVICE, UNICODE_UTF8 );

    rDateRegionServiceKey   :=  DBMS_CRYPTO.MAC
                                (
                                    src => rSource,
                                    typ => DBMS_CRYPTO.HMAC_SH256,
                                    key => rDateRegionKey
                                );

    IF bDebug = DEBUG_VERBOSE
    THEN
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('================================================================' );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('vcAwsV4SignedKey.DBMS_CRYPTO.MAC AWS Service' );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('AWS Service:-           ' || AWS_SERVICE );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('rSource:-               ' || rSource );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('rDateRegionServiceKey:- ' || rDateRegionServiceKey );
    END IF;

    rSource  := UTL_I18N.STRING_TO_RAW( AWS_REQUEST, UNICODE_UTF8 );

    rSigningKey :=  DBMS_CRYPTO.MAC
                    (
                        src => rSource,
                        typ => DBMS_CRYPTO.hmac_sh256,
                        key => rDateRegionServiceKey
                    );

    IF bDebug = DEBUG_VERBOSE
    THEN
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('================================================================' );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('vcAwsV4SignedKey.DBMS_CRYPTO.MAC AWS Request' );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('AWS Request:-   ' || AWS_REQUEST );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('rSource:-       ' || rSource );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('rSigningKey:-   ' || rSigningKey );
    END IF;

    rSource     := UTL_I18N.STRING_TO_RAW( pStringToSign, UNICODE_UTF8 );

    rSignature  := DBMS_CRYPTO.MAC
                    (
                        src => rSource,
                        typ => DBMS_CRYPTO.hmac_sh256,
                        key => rSigningKey
                    );

    IF bDebug = DEBUG_VERBOSE
    THEN
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('================================================================' );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('vcAwsV4SignedKey.DBMS_CRYPTO.MAC String to Sign' );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('pStringToSign:- ' || pStringToSign );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('rSource:-       ' || rSource );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('rSignature:-    ' || rSignature );
    END IF;

    szReturn := LOWER( RAWTOHEX ( rSignature ));

    RETURN szReturn;

END vcAwsV4SignedKey;
--------------------------------------------------------------------------------
FUNCTION    vcCreateStringToSign
            (
                pStringToSign   IN VARCHAR2,
                pDate           IN DATE
            )
    RETURN  VARCHAR2
/*  ----------------------------------------------------------------------------
* Routine Name: vcCreateStringToSign
*
* Description:  Creates the signed string in accordance with AWS API Documentation
*               http://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
*
* Arguments:    IN      pStringToSign
*               IN      pDate
*
* Returns:              vcStringToSign  The formatted string to sign
----------------------------------------------------------------------------- */
AS
    vcDateString    VARCHAR2(8);
    vcISO_8601_Date VARCHAR2(22);
    vcStringToSign  VARCHAR2(4000);

BEGIN

    vcISO_8601_Date:= vcReturnISO_8601_Date( pDate, TIME_ZONE );
    vcDateString   := TO_CHAR( pDate, DATE_FORMAT_URL );

    vcStringToSign :=   AWS_AUTH_MECHANISM     || LINE_FEED    ||
                        vcISO_8601_Date        || LINE_FEED    ||
                        vcDateString           || SLASH        ||
                        AWS_REGION             ||
                        AWS_V4_REQUEST_DOMAIN  || LINE_FEED    ||
                        pStringToSign;

    RETURN(vcStringToSign);

END vcCreateStringToSign;
--------------------------------------------------------------------------------
FUNCTION    vcEncodeUrlAmpersand
            (
                pURL    IN VARCHAR2
            )
    RETURN  VARCHAR2
/*  ----------------------------------------------------------------------------
* Routine Name: vcEncodeUrlAmpersand
*
* Description:  Prepares the URL string
*
* Arguments:    IN      pURL            The URL String to be modified
*
* Returns:              szReturn        the AWS4 escape value
----------------------------------------------------------------------------- */
AS
    szReturn  VARCHAR2(1024);

BEGIN

    szReturn  := REPLACE( UTL_URL.ESCAPE( pURL ), AMPERSAND, URL_AMPERSAND );

    RETURN szReturn;

END vcEncodeUrlAmpersand;
--------------------------------------------------------------------------------
FUNCTION    vcGetCanonicalRequest
            (
                pBucket             IN      VARCHAR2,
                pHttpMethod         IN      VARCHAR2,
                pCanonicalUri       IN      VARCHAR2,
                pQueryString        IN      VARCHAR2    DEFAULT NULL,
                pDate               IN      DATE,
                pPayloadHash        IN      VARCHAR2,
                pCanonicalRequest       OUT VARCHAR2,
                pURL                    OUT VARCHAR2
            )
    RETURN  VARCHAR2
/*  ----------------------------------------------------------------------------
* Routine Name: vcGetCanonicalRequest
*
* Description:  Generates the Canonical Request and the corresponding URL as
*               documented by AWS.
*               http://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
*
*               If AWS RETURNs errors the cause is most likely found IN the canonical
*               request, even if the signature doesn't match the error.
*
* Notes:        The us-east-1 also called us-standard doesn't follow the same
*               canonical rules as other newer buckets.
*               What works for eu-central-1 does not work for us-east-1.
*
* Arguments:    IN      pBucket
*               IN      pHttpMethod
*               IN      pCanonicalUri
*               IN      pDate
*               IN      pPayloadHash
*
* Returns:              szReturn        The signed value
----------------------------------------------------------------------------- */
AS
    vcCanonicalUri      VARCHAR2(4000);
    vcCanonicalRequest  VARCHAR2(4000);
    vcQueryString       VARCHAR2(1000);
    vcUri               VARCHAR2(1000);
    vcHeader            VARCHAR2(1000);
    vcSignedHeader      VARCHAR2(1000);
    vcHost              VARCHAR2(100);
    vcRequestHashed     VARCHAR2(100);

BEGIN
 -- Can't find anyway to parameterise the calling function name, so have to hard code it
    vValidateHttpMethod( pHttpMethod, 'vcGetCanonicalRequest' );

    vcQueryString := pQueryString;

    IF SUBSTR( pCanonicalUri, 1, 1 ) != SLASH
    THEN
        vcCanonicalUri := SLASH || pCanonicalUri;
    ELSE
        vcCanonicalUri := pCanonicalUri;
    END IF;

    IF pBucket IS NOT NULL
    then
        IF REGION_US_STANDARD = AWS_REGION
        THEN
            vcHost  := HOST_CMD || US_STANDARD_REGION_DOMAIN;
            vcUri   := vcEncodeUrlAmpersand( SLASH                  || pBucket || vcCanonicalUri );
            pURL    := vcEncodeUrlAmpersand( US_STANDARD_REGION_URL || pBucket || vcCanonicalUri );
        else
            IF  vcCanonicalUri is NULL
            OR  vcCanonicalUri = SLASH
            then
                vcUri := SLASH;
            else
                vcUri := vcEncodeUrlAmpersand( vcCanonicalUri );
            END IF;

            vcHost  :=  HOST_CMD || pBucket || S3_BUCKET_DELIMITER || AWS_REGION || US_OTHER_REGIONS_DOMAIN;
            pURL    :=  vcEncodeUrlAmpersand
                        (
                            HTTPS_CMD               ||
                            pBucket                 ||
                            S3_BUCKET_DELIMITER     ||
                            AWS_REGION              ||
                            US_OTHER_REGIONS_DOMAIN ||
                            vcCanonicalUri
                        );
        END IF;
    else
        vcHost      := HOST_CMD || US_STANDARD_REGION_DOMAIN;
        vcUri       := vcEncodeUrlAmpersand( vcCanonicalUri );
        pURL        := vcEncodeUrlAmpersand( US_STANDARD_REGION_URL );
    END IF;

    vcHeader        :=  vcHost                                      || LINE_FEED ||
                        AWS_V4_CONTENT_HEADER                       ||
                        pPayloadHash                                || LINE_FEED ||
                        AWS_V4_DATE_HEADER                          ||
                        vcReturnISO_8601_Date( pDate, TIME_ZONE )   || LINE_FEED;

    vcSignedHeader  :=  HOST                    ||
                        AWS_V4_HEADER_DELIMITER ||
                        AWS_V4_CONTENT          ||
                        AWS_V4_HEADER_DELIMITER ||
                        AWS_V4_DATE;

    vcCanonicalRequest :=   pHttpMethod     || LINE_FEED ||
                            vcUri           || LINE_FEED ||
                            vcQueryString   || LINE_FEED ||
                            vcHeader        || LINE_FEED ||
                            vcSignedHeader  || LINE_FEED ||
                            pPayloadHash;

    pCanonicalRequest := vcCanonicalRequest;

    IF vcQueryString IS NOT NULL
    THEN
        pURL := pURL || vcQueryString;
    END IF;

    vcRequestHashed    := LOWER( vcAwsV4CryptoHash( vcCanonicalRequest ));

    IF bDebug = DEBUG_VERBOSE
    THEN
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('================================================================' );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE( 'vcGetCanonicalRequest' );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE( 'Bucket:-            '    || pBucket );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE( 'HTTP Method:-       '    || pHttpMethod );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE( 'Canonical URI:-     '    || pCanonicalUri );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE( 'Query String:-      '    || pQueryString );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE( 'Date:-              '    || TO_CHAR( pDate, 'DD-MON-YYYY' ));
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE( 'Payload Hash:-      '    || pPayloadHash );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE( 'Header:-            '    || vcHeader );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE( 'Signed Header:-     '    || vcSignedHeader );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE( 'Canonical Request:- '    || pCanonicalRequest );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE( 'URL:-               '    || pURL );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE( 'Request Hashed:-    '    || vcRequestHashed );
    END IF;

    RETURN vcRequestHashed;

END  ;
--------------------------------------------------------------------------------
FUNCTION    vcPrepareAwsData
            (
                pBucket             IN      VARCHAR2,
                pHttpMethod         IN      VARCHAR2,
                pCanonicalUri       IN      VARCHAR2,
                pQueryString        IN      VARCHAR2    DEFAULT NULL,
                pDate               IN      DATE,
                pPayloadHash        IN      VARCHAR2,
                pURL                   OUT  VARCHAR2
            )
    RETURN  VARCHAR2
/*  ----------------------------------------------------------------------------
* Routine Name: vcPrepareAwsData
*
* Description:  Performs the following 3 actions
*               Task 1  Creates a Canonical Request and creates the URL so that
*                       they match.
*               Task 2  Creates a String to Sign
*               Task 3  Calculates the Signature
*               http://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
*
* Arguments:    IN      pBucket
*               IN      pHttpMethod
*               IN      pCanonicalUri
*               IN      pDate
*               IN      pPayloadHash
*                  OUT  pCanonicalRequest
*                  OUT  pURL
*
* Returns:              vcSignedString  The signed string
----------------------------------------------------------------------------- */
AS
    vcRequestHashed     VARCHAR2(100);
    vcSignature         VARCHAR2(100);
    vcCanonicalRequest  VARCHAR2(4000);

BEGIN
    vcRequestHashed :=  vcGetCanonicalRequest
                        (
                            pBucket             => pBucket,
                            pHttpMethod         => pHttpMethod,
                            pCanonicalUri       => pCanonicalUri,
                            pQueryString        => pQueryString,
                            pDate               => pDate,
                            pPayloadHash        => pPayloadHash,
                            pCanonicalRequest   => vcCanonicalRequest,
                            pURL                => pURL
                        );

    vcSignature  := vcSignString
                    (
                        pStringToSign   => vcRequestHashed,
                        pDate           => pDate
                    );

    IF bDebug = DEBUG_VERBOSE
    THEN
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('================================================================' );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('vcPrepareAwsData' );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('Bucket Name: -        ' || pBucket );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('HTTP Method: -        ' || pHttpMethod );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('Canonical URI: -      ' || pCanonicalUri );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE( 'Query String:-       ' || pQueryString );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('Date: -               ' || pDate );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('Payload Hash: -       ' || pPayloadHash );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('Canonical Request: -  ' || vcCanonicalRequest );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('URL: -                ' || pURL );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('Request Hashed: -     ' || vcRequestHashed );
        DBMS_OUTPUT.PUT( TWO_TAB_CHARACTERS );
        DBMS_OUTPUT.PUT_LINE('Signature: -          ' || vcSignature );
    END IF;

    RETURN vcSignature;

END vcPrepareAwsData;
--------------------------------------------------------------------------------
FUNCTION    vcReturnISO_8601_Date
            (
                pDate       IN TIMESTAMP,
                pTimezone   IN VARCHAR2
            )
    RETURN  VARCHAR2
/*  ----------------------------------------------------------------------------
* Routine Name: vcReturnISO_8601_Date
*
* Description:  Generates a varchar date IN the ISO_8601 format.
*
*               The FUNCTION Also converts from the provided timezone to UTC/GMT.
*
* Arguments:    IN      pDate       The date to  be converted as a timestamp
*               IN      pTimezone   The timezone of the current date
*
* Returns:              szReturn        The signed value
----------------------------------------------------------------------------- */
AS
    tTimestamp      TIMESTAMP;
    vcISO_8601_Date VARCHAR2(22);

BEGIN

    tTimestamp   := cast( pDate AS TIMESTAMP WITH TIME ZONE ) AT TIME ZONE pTimezone;

    IF tTimestamp IS NOT NULL
    then
        vcISO_8601_Date := TO_CHAR( tTimestamp, ISO8601_DATE_FORMAT ) ;
    else
        vcISO_8601_Date := null;
    END IF;

    RETURN vcISO_8601_Date;

END vcReturnISO_8601_Date;
--------------------------------------------------------------------------------
FUNCTION    vcSignString
            (
                pStringToSign   IN VARCHAR2,
                pDate           IN DATE
            )
    RETURN  VARCHAR2
/*  ----------------------------------------------------------------------------
* Routine Name: vcSignString
*
* Description:  accepts a string and date value, which are used to create a signed
*               value that will match the value that S3 signs.
*
* Arguments:    IN      pStringToSign
*               IN      pDate
*
* Returns:              vcSignedString  The signed string
----------------------------------------------------------------------------- */
AS
    vcSignedString  VARCHAR2(100);
    vcStringToSign  VARCHAR2(4000);

BEGIN

    vcStringToSign := vcCreateStringToSign( pStringToSign, pDate );
    vcSignedString := vcAwsV4SignedKey( vcStringToSign, pDate );

    RETURN vcSignedString;

END vcSignString;
--------------------------------------------------------------------------------
PROCEDURE   vCheckForErrorsB
            (
                pBlob   IN  BLOB
            )
/*  ----------------------------------------------------------------------------
* Routine Name: vCheckForErrors
*
* Description:  Check for an error condition in the HTTPS return string and raise
*               an EXCEPTION, containing all relevant infomation if one is found.
*
* Arguments:    IN      pClob   The string to be examined
*
* Returns:              NULL
----------------------------------------------------------------------------- */
AS
    XMLString       XMLTYPE;
    vcReturnString  VARCHAR2(32767);

BEGIN

    IF  DBMS_LOB.GETLENGTH( pBlob ) > 0
    THEN
        vcReturnString :=   UTL_RAW.CAST_TO_VARCHAR2
                            (
                                DBMS_LOB.SUBSTR
                                (
                                    pBlob,
                                    MAX_UTL_FILE_WRITE_SIZE,
                                    SRC_START_OFFSET
                                )
                            );

        if INSTR( vcReturnString, XML_HEADER ) > 0
        THEN
            XMLString := XMLTYPE( vcReturnString );

            vCheckForErrors( XMLString );
        END IF;
    END IF;

END vCheckForErrorsB;
--------------------------------------------------------------------------------
PROCEDURE   vCheckForErrors
            (
                pClob   IN  CLOB
            )
/*  ----------------------------------------------------------------------------
* Routine Name: vCheckForErrors
*
* Description:  Check for an error condition in the HTTPS return string and raise
*               an EXCEPTION, containing all relevant infomation if one is found.
*
* Arguments:    IN      pClob   The string to be examined
*
* Returns:              NULL
----------------------------------------------------------------------------- */
AS
    XMLString   XMLTYPE;

BEGIN

    IF  pClob IS NOT NULL
    AND LENGTH( pClob ) > 0
    THEN
        XMLString := XMLTYPE( pClob );

        vCheckForErrors( XMLString );
    END IF;

END vCheckForErrors;
--------------------------------------------------------------------------------
PROCEDURE   vCheckForErrors
            (
                pXMLString  IN  XMLTYPE
            )
/*  ----------------------------------------------------------------------------
* Routine Name: vCheckForErrors
*
* Description:  Check for an error condition in the HTTPS return string and raise
*               an, containing all relevant infomation if one is found.
*
* NOTE:         This routine must come first to allow the overloaded version that
*               follows to call it
*
* Arguments:    IN      pXMLString   The string to be examined
*
* Returns:              NULL
----------------------------------------------------------------------------- */
AS

BEGIN
    IF pXMLString.EXISTSNODE( XML_ERROR_STRING ) = 1
    THEN
        RAISE_APPLICATION_ERROR
        (
            AWS_S3_EXCEPTION,
            pXMLString.EXTRACT( XML_ERROR_MESSAGE ).GETSTRINGVAL()
        );
    END IF;

END vCheckForErrors;
--------------------------------------------------------------------------------
PROCEDURE   vPrepareRestHeader
            (
                pDateString     IN      VARCHAR2,
                pSignature      IN      VARCHAR2,
                pPayloadHash    IN      VARCHAR2,
                pISO_8601Date   IN      VARCHAR2,
                pLength         IN      BINARY_INTEGER  DEFAULT 0
            )
/*  ----------------------------------------------------------------------------
* Routine Name: vPrepareRestHeader
*
* Description:  This is the heart of the programme along with the Make Request routines,
*               This procedure constructs the APE Request Headers
*               http://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
*
* Arguments:    IN      pDateString
*               IN      pSignature
*               IN      pPayloadHash
*               IN      pISO_8601Date
*
* Returns:              NULL
----------------------------------------------------------------------------- */
AS

BEGIN
    IF bDebug > DEBUG_ON
    THEN
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('========================================================================' );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('vPrepareRestHeader' );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('AWS Access Key: -     ' || AWS_ACCESS_KEY );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('AWS Region:     -     ' || AWS_REGION );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('AWS Host:       -     ' || HOST );
    END IF;

    APEX_WEB_SERVICE.G_REQUEST_HEADERS(1).name  :=  HTTP_AUTHORISATION;
    APEX_WEB_SERVICE.G_REQUEST_HEADERS(1).value :=  AWS_AUTH_MECHANISM      ||  SPACE_DELIMITER ||
                                                    HTTP_CREDENTIAL_REQ     ||  AWS_ACCESS_KEY  || SLASH    ||
                                                                                pDateString     || SLASH    ||
                                                                                AWS_REGION      ||
                                                    AWS_V4_REQUEST_DOMAIN   ||  COMMA_DELIMITER ||
                                                    HTTP_SIGNED_HEADER_REQ  ||  HOST            || AWS_V4_HEADER_DELIMITER ||
                                                                                AWS_V4_CONTENT  || AWS_V4_HEADER_DELIMITER ||
                                                                                AWS_V4_DATE     || COMMA_DELIMITER         ||
                                                    HTTP_SIGNATURE_REQ      ||  pSignature;

    APEX_WEB_SERVICE.G_REQUEST_HEADERS(2).name  := AWS_V4_CONTENT;
    APEX_WEB_SERVICE.G_REQUEST_HEADERS(2).value := pPayloadHash ;

    APEX_WEB_SERVICE.G_REQUEST_HEADERS(3).name  := AWS_V4_DATE;
    APEX_WEB_SERVICE.G_REQUEST_HEADERS(3).value := pISO_8601Date;

    IF pLength > 0
    THEN
        APEX_WEB_SERVICE.G_REQUEST_HEADERS(4).name  := AWS_V4_CONTENT_TYPE;
        APEX_WEB_SERVICE.G_REQUEST_HEADERS(4).value := AWS_V4_MIME_TYPE;

        APEX_WEB_SERVICE.G_REQUEST_HEADERS(5).name  := AWS_V4_CONTENT_LENGTH;
        APEX_WEB_SERVICE.G_REQUEST_HEADERS(5).value := pLength;
    END IF;

    IF bDebug > DEBUG_ON
    THEN
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('Header 1 Name:  -     ' || APEX_WEB_SERVICE.G_REQUEST_HEADERS(1).name );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('Header 1 Value: -     ' || APEX_WEB_SERVICE.G_REQUEST_HEADERS(1).value );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('Header 2 Name:  -     ' || APEX_WEB_SERVICE.G_REQUEST_HEADERS(2).name );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('Header 2 Value: -     ' || APEX_WEB_SERVICE.G_REQUEST_HEADERS(2).value );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('Header 3 Name:  -     ' || APEX_WEB_SERVICE.G_REQUEST_HEADERS(3).name );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('Header 3 Value: -     ' || APEX_WEB_SERVICE.G_REQUEST_HEADERS(3).value );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('Header 4 Name:  -     ' || CASE WHEN pLength > 0 THEN APEX_WEB_SERVICE.G_REQUEST_HEADERS(4).name ELSE NULL END );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('Header 4 Value: -     ' || CASE WHEN pLength > 0 THEN APEX_WEB_SERVICE.G_REQUEST_HEADERS(4).value ELSE NULL END );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('Header 5 Name:  -     ' || CASE WHEN pLength > 0 THEN APEX_WEB_SERVICE.G_REQUEST_HEADERS(5).name ELSE NULL END );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('Header 5 Value: -     ' || CASE WHEN pLength > 0 THEN APEX_WEB_SERVICE.G_REQUEST_HEADERS(5).value ELSE NULL END );
    END IF;

END vPrepareRestHeader;
--------------------------------------------------------------------------------
PROCEDURE   vPutOracleFile
            (
                pDirectoryName  IN      VARCHAR2,
                pBlob           IN      BLOB,
                pFileName       IN      VARCHAR2
            )
/*  ----------------------------------------------------------------------------
* Routine Name: vPutOracleFile
*
* Description:  Writes a the contents of the Blob to a file in an Oracle Directory.
*
* Arguments:    IN      pDirectoryName  The name of the Oracle Directoryt
*               IN      pBlob           The Contents of the file as type RAW/BLOB
*               IN      pFileName       The name of the file
*
* Returns:              NULL
----------------------------------------------------------------------------- */
AS
    iBlobChunkSize  BINARY_INTEGER  := LEAST( DBMS_LOB.GETCHUNKSIZE( pBlob ), MAX_UTL_FILE_WRITE_SIZE );
    iFileLength     BINARY_INTEGER  := DBMS_LOB.GETLENGTH( pBlob );
    iFilePointer    BINARY_INTEGER  := 1;

    bShortBlob      BLOB            := EMPTY_BLOB();

    ftOutputFile    UTL_FILE.FILE_TYPE;

BEGIN
    IF bDebug > DEBUG_ON
    THEN
        DBMS_OUTPUT.PUT_LINE('>>>');
        DBMS_OUTPUT.PUT_LINE('================================================================================' );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('vPutOracleFile' );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('Directory name -      ' || pDirectoryName );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('Object Length: -      ' || iFileLength );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('Object Chunk Size: -  ' || iBlobChunkSize );
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE('File Name -           ' || pFileName );
    END IF;

    ftOutputFile := UTL_FILE.FOPEN
                    (
                        location        => pDirectoryName,
                        filename        => pFileName,
                        open_mode       => UTL_FILE_WRITE_BYTE_MODE,
                        max_linesize    => iBlobChunkSize
                    );

    if EMPTY_FILE = DBMS_LOB.GETLENGTH( pBlob )
    THEN
        UTL_FILE.PUT_RAW
        (
            ftOutputFile,
            bShortBlob,
            TRUE
        );
    ELSE
        WHILE iFilePointer < iBlobChunkSize
        LOOP
            DBMS_LOB.READ
            (
                pBlob,
                iBlobChunkSize,
                iFilePointer,
                bShortBlob
            );

            UTL_FILE.PUT_RAW
            (
                ftOutputFile,
                bShortBlob,
                TRUE
            );

            iFilePointer := iFilePointer + iBlobChunkSize;

        END LOOP;
    END IF;

    UTL_FILE.FFLUSH( ftOutputFile );
    UTL_FILE.FCLOSE( ftOutputFile );

    IF bDebug > DEBUG_ON
    THEN
        DBMS_OUTPUT.PUT( TAB_CHARACTER );
        DBMS_OUTPUT.PUT_LINE( iFilePointer - 1 || ' bytes writtern to ' || pDirectoryName || ' ' || pFileName );
        DBMS_OUTPUT.PUT_LINE('<<<');
    END IF;

END vPutOracleFile;
--------------------------------------------------------------------------------
PROCEDURE   vValidateHttpMethod
            (
                pHttpMethod     IN  VARCHAR2,
                pProcedure      IN  VARCHAR2
            )
/*  ----------------------------------------------------------------------------
* Routine Name: vValidateHttpMethod
*
* Description:  Confirms HTTP method - GET, POST, PUT, DELETE
*
* Arguments:    IN      pHttpMethod     The method requested
*               IN      pProcedure      The procedure that made the request
*
* Returns:                              None
----------------------------------------------------------------------------- */
AS
    bIsValid    BOOLEAN := false;

BEGIN
    IF  pHttpMethod IN(
                        HTTP_GET_METHOD,
                        HTTP_HEAD_METHOD,
                        HTTP_POST_METHOD,
                        HTTP_PUT_METHOD,
                        HTTP_DELETE_METHOD
                    )
    THEN
        bIsValid := TRUE;
    ELSE
        bIsValid := FALSE;
        RAISE_APPLICATION_ERROR
        (
            AWS_S3_EXCEPTION,
           'HTTP Method is not valid IN aws_rds_to_s3_pkg.' || pProcedure
        );
    END IF;

END vValidateHttpMethod;
--------------------------------------------------------------------------------
--                              S E C T I O N
--
--                PUBLIC MANAGEMENT FUNCTIONS AND PROCEDURES
--                ------------------------------------------
--
-- These should be kept alphabetized within types
--------------------------------------------------------------------------------
PROCEDURE   setAwsKeys
            (
                pAwsID      IN      VARCHAR2,
                pAwsKey     IN      VARCHAR2
            )
/*  ----------------------------------------------------------------------------
* Routine Name: setAwsKeys
*
* Description:  Sets the AWS access keys
*
* Arguments:    IN      pAwsID      The AWS S3 Access key ID
*               IN      pAwsKey     The AWS S3 Secret access key
*
* Returns:              NULL
----------------------------------------------------------------------------- */
AS

BEGIN
    AWS_ACCESS_KEY   := pAwsID;
    AWS_SECRET_KEY   := pAwsKey;

END setAwsKeys;
--------------------------------------------------------------------------------
PROCEDURE   setAwsRegion
            (
                pAwsRegion      IN      VARCHAR2
            )
/*  ----------------------------------------------------------------------------
* Routine Name: setAwsRegion
*
* Description:  Turns off debugging.
*               This is the default state of the package
*
* Arguments:    IN      pAwsRegion  The region against which the commands are
*                                   to be run
*
* Returns:              NULL
----------------------------------------------------------------------------- */
AS

BEGIN
    AWS_REGION := pAwsRegion;

END setAwsRegion;
--------------------------------------------------------------------------------
PROCEDURE   setDebugOff
/*  ----------------------------------------------------------------------------
* Routine Name: setDebugOff
*
* Description:  Turns off debugging.
*               This is the default state of the package
*
* Arguments:    IN      NULL
*
* Returns:              NULL
----------------------------------------------------------------------------- */
AS

BEGIN
    bDebug   := DEBUG_OFF;

END setDebugOff;
--------------------------------------------------------------------------------
PROCEDURE   setDebugOn
            (
                bMode       IN      BINARY_INTEGER  DEFAULT DEBUG_ON
            )
/*  ----------------------------------------------------------------------------
* Routine Name: setDebugOn
*
* Description:  Turns on debugging so that you can see what variables are being
*               set in the program
*
* Note:         For security reasons only the package owner can run in debug levels
*               2 & 3
*
* Arguments:    IN      bMode       The Level of debugging
*                       DEFAULT     1   Informational only
*                                   2   Shows the Connection information
*                                   3   Full verbose mode
*
* Returns:              NULL
----------------------------------------------------------------------------- */
AS
    CURSOR  cGetOwner
    IS
    SELECT
            owner
    FROM
            all_source
    WHERE
            line    = 1
    AND     type    = 'PACKAGE'
    AND     name    = $$plsql_unit;

    vcPackageOwner  VARCHAR2(128);

BEGIN
    bDebug := DEBUG_ON;

    OPEN    cGetOwner;
    FETCH   cGetOwner
    INTO    vcPackageOwner;
    CLOSE   cGetOwner;

    IF vcPackageOwner = USER
    THEN
        bDebug := bMode;
    END IF;

END setDebugOn;
--------------------------------------------------------------------------------
PROCEDURE   setTimeZone
            (
                pTimeZone   IN      VARCHAR2
            )
/*  ----------------------------------------------------------------------------
* Routine Name: setTimeZone
*
* Description:  Sets the timesone, used to create the ISO 8601 Date.
*
* Notes:        A list of Time Zones can be found at
*               https://en.wikipedia.org/wiki/List_of_tz_database_time_zones
*
*
* Arguments:    IN      pTimeZone   The timezone to use
*
* Returns:              NULL
----------------------------------------------------------------------------- */
AS

BEGIN
    TIME_ZONE := pTimeZone;

END setTimeZone;
--------------------------------------------------------------------------------
PROCEDURE   setWalletPassword
            (
                pWalletPwd      IN      VARCHAR2
            )
/*  ----------------------------------------------------------------------------
* Routine Name: setWalletPassword
*
* Description:  Sets the password for the wallet.
*
* Arguments:    IN      pWalletPwd  The password of the wallet
*
* Returns:              NULL
----------------------------------------------------------------------------- */
AS

BEGIN
    WALLET_PASSWORD := pWalletPwd;

END setWalletPassword;
--------------------------------------------------------------------------------
--                              S E C T I O N
--
--                PUBLIC EXECUTION FUNCTIONS AND PROCEDURES
--                -----------------------------------------
--
-- These should be kept alphabetized within types
--------------------------------------------------------------------------------
PROCEDURE   awsHelp
AS
BEGIN
    DBMS_OUTPUT.PUT_LINE( HELP_TEXT );

END awsHelp;
--------------------------------------------------------------------------------
PROCEDURE   copyFile
            (
                pSource         IN      VARCHAR2,
                pFileName       IN      VARCHAR2,
                pDestination    IN      VARCHAR2,
                pPrefix         IN      VARCHAR2        DEFAULT NULL
            )
/*  ----------------------------------------------------------------------------
* Routine Name: copyFile
*
* Description:  Copies files between Oracle Directories and S3 Buckets.
*               This procedure will all files to be copied in either direction
*               from the source location to the destination
*               A check is carried out against the Source Location to determine if
*               it is a valid Oracle Directory and this is used to determin the
*               direction of the copy
*
* Notes:        This routine copies single files only and will error if wild cards
*               are entered
*
* Arguments:    IN      pSource         Where the file currently resides
*               IN      pFileName       The name of the object to be copied
*               IN      pDestination    Where to put it
*               IN      pPrefix         The folder name, known as a prefix in S3
*
* Returns:              NULL
----------------------------------------------------------------------------- */
AS
    CURSOR  cGetDirectory
    IS
    SELECT
            owner
    FROM
            all_directories
    WHERE
            directory_name  = pSource;

    vcDirectoryOwner    VARCHAR2(128)   := SOURCE_IS_BUCKET;
    vcFileContents      BLOB;

BEGIN
    IF bDebug > DEBUG_OFF
    THEN
        DBMS_OUTPUT.PUT_LINE('>>>');
        DBMS_OUTPUT.PUT_LINE('================================================================================' );
        DBMS_OUTPUT.PUT_LINE('copyFile' );
        DBMS_OUTPUT.PUT_LINE('Source Directory: -      ' || pSource );
        DBMS_OUTPUT.PUT_LINE('File Name: -             ' || pFileName );
        DBMS_OUTPUT.PUT_LINE('Destination Directory: - ' || pDestination );
        DBMS_OUTPUT.PUT_LINE('Optional Prefix -        ' || pPrefix);
    END IF;

    OPEN    cGetDirectory;
    FETCH   cGetDirectory
    INTO    vcDirectoryOwner;
    CLOSE   cGetDirectory;

    IF SOURCE_IS_BUCKET = vcDirectoryOwner
    THEN
        IF bDebug > DEBUG_OFF
        THEN
            DBMS_OUTPUT.PUT_LINE('Source Directory is an S3 Bucket' );
            DBMS_OUTPUT.PUT_LINE('<<<');
        END IF;
        vcFileContents := getObjectBlob( pSource, pFileName, pPrefix );
        vPutOracleFile( pDestination, vcFileContents, pFileName );
    ELSE
        IF bDebug > DEBUG_OFF
        THEN
            DBMS_OUTPUT.PUT_LINE('Source Directory is an Oracle Directory' );
            DBMS_OUTPUT.PUT_LINE('<<<');
        END IF;
        vcFileContents := bGetOracleFile( pSource, pFileName );
        putObjectBlob( pDestination, vcFileContents, pFileName, pPrefix );
    END IF;

END copyFile;
--------------------------------------------------------------------------------
PROCEDURE   deleteObject
            (
                pBucket         IN      VARCHAR2,
                pObjectName     IN      VARCHAR2,
                pPrefix         IN      VARCHAR2        DEFAULT NULL
            )
/*  ----------------------------------------------------------------------------
* Routine Name: deleteObject
*
* Description:  Deletes an AWS S3 object
*
* Arguments:    IN      pBucket         The name of the bucket containing the object
*               IN      pObject         The name of the object to be deleted
*
* Returns:              NULL
----------------------------------------------------------------------------- */
AS
    dLocalTimestamp     DATE;
    vcCanonicalUri      VARCHAR2(128);
    vcDateString        VARCHAR2(8);
    vcISO_8601_Date     VARCHAR2(22);
    vcHttpMethod        VARCHAR2(10);
    vcSignature         VARCHAR2(4000);
    vcUrl               VARCHAR2(4000);
    vcPayloadHash       VARCHAR2(100);
    lClob               CLOB;

BEGIN
    IF bDebug > DEBUG_OFF
    THEN
        DBMS_OUTPUT.PUT_LINE('>>>');
        DBMS_OUTPUT.PUT_LINE('================================================================================' );
        DBMS_OUTPUT.PUT_LINE('deleteObject' );
        DBMS_OUTPUT.PUT_LINE('Bucket Name: -    ' || pBucket );
        DBMS_OUTPUT.PUT_LINE('Object Name: -    ' || pObjectName );
        DBMS_OUTPUT.PUT_LINE('Optional Prefix - ' || pPrefix );
    END IF;

    dLocalTimestamp := localtimestamp;
    vcDateString    := TO_CHAR( dLocalTimestamp, DATE_FORMAT_URL );
    vcISO_8601_Date := vcReturnISO_8601_Date( dLocalTimestamp, TIME_ZONE );
    vcHttpMethod    := HTTP_DELETE_METHOD;
    vcPayloadHash   := NULL_SHA256__HASH;
    vcCanonicalUri  := pPrefix || SLASH|| pObjectName;

    vcSignature  := vcPrepareAwsData
                    (
                        pBucket             => pBucket,
                        pHttpMethod         => vcHttpMethod,
                        pCanonicalUri       => vcCanonicalUri,
                        pDate               => dLocalTimestamp,
                        pPayloadHash        => vcPayloadHash,
                        pURL                => vcUrl
                    );

    lClob   :=  cMakeRestRequest
    (
        vcDateString,
        vcSignature,
        vcPayloadHash,
        vcISO_8601_Date,
        vcURL,
        HTTP_DELETE_METHOD
    );

    vCheckForErrors( lClob );

    IF bDebug > DEBUG_OFF
    THEN
        DBMS_OUTPUT.PUT_LINE('Returned:    - ' || lClob );
        DBMS_OUTPUT.PUT_LINE('<<<');
    END IF;

END deleteObject;
--------------------------------------------------------------------------------
FUNCTION getBucketList
    RETURN  BUCKET_LIST
/*  ----------------------------------------------------------------------------
* Routine Name: getBucketList
*
* Description:  Queries the S3 environment and returns a list of all buckets that
*               the user has access to
*
* Notes:        Running a bucket list only works against us-east-1 and so you have to
*               change the region for a bucket list query and then put it back at the end
*               So I  record the current region at the beginning and revert it at the end
*
* Arguments:    IN      Null
*
* Returns:              lBucketList     An array containing the list of buckets
----------------------------------------------------------------------------- */
AS
    dLocalTimestamp     DATE;

    vcDateString        VARCHAR2(8);
    vcISO_8601_Date     VARCHAR2(22);
    vcPayloadHash       VARCHAR2(100);
    vcHttpMethod        VARCHAR2(10);
    vcRequestHashed     VARCHAR2(4000);
    vcSignature         VARCHAR2(4000);
    vcURL               VARCHAR2(4000);
    vcCurrentRegion     VARCHAR2(16)    := AWS_REGION;

    lClob               CLOB;
    lXml                xmltype;
    iCount              BINARY_INTEGER  := 0;
    lBucketList         BUCKET_LIST;

    CURSOR  cExtractBucketNames
    IS
    SELECT
            extractValue( value(t), XML_BUCKET_NAME,   AWS_NAMESPACE_S3_FULL ) AS bucket_name,
            extractValue( value(t), XML_CREATION_DATE, AWS_NAMESPACE_S3_FULL ) AS creation_date
    FROM
            TABLE( xmlsequence( lXml.extract( XML_LIST_ALL_BUCKETS, AWS_NAMESPACE_S3_FULL ))) t;

BEGIN
    AWS_REGION      := REGION_US_STANDARD;

    IF bDebug > DEBUG_OFF
    THEN
        DBMS_OUTPUT.PUT_LINE('>>>');
        DBMS_OUTPUT.PUT_LINE('================================================================================' );
        DBMS_OUTPUT.PUT_LINE('getBucketList' );
        DBMS_OUTPUT.PUT_LINE('Current Region: -          ' || vcCurrentRegion );
        DBMS_OUTPUT.PUT_LINE('Active Region at Start: -  ' || AWS_REGION );
    END IF;

    dLocalTimestamp := localtimestamp;
    vcDateString    := TO_CHAR( dLocalTimestamp, DATE_FORMAT_URL );
    vcISO_8601_Date := vcReturnISO_8601_Date( dLocalTimestamp, TIME_ZONE );
    vcPayloadHash   := NULL_SHA256__HASH;

    vcSignature :=  vcPrepareAwsData
                    (
                        pBucket             => NULL,
                        pHttpMethod         => HTTP_GET_METHOD,
                        pCanonicalUri       => SLASH,
                        pDate               => dLocalTimestamp,
                        pPayloadHash        => vcPayloadHash,
                        pURL                => vcURL
                );

    lClob   :=  cMakeRestRequest
                (
                    vcDateString,
                    vcSignature,
                    vcPayloadHash,
                    vcISO_8601_Date,
                    vcURL,
                    HTTP_GET_METHOD
                );

    vCheckForErrors( lClob );

    IF lClob IS NOT NULL
    then
        lXml := XMLTYPE( lClob );

        for rExtractBucketNames IN cExtractBucketNames
        LOOP
            iCount                              := iCount + 1;
            lBucketList(iCount).bucket_name     := rExtractBucketNames.bucket_name;
            lBucketList(iCount).creation_date   := TO_DATE( rExtractBucketNames.creation_date, DATE_FORMAT_XML );
        END LOOP;
    END IF;

    AWS_REGION := vcCurrentRegion;

    IF bDebug > DEBUG_OFF
    THEN
        DBMS_OUTPUT.PUT_LINE('Active Region at End: -    ' || AWS_REGION );
        DBMS_OUTPUT.PUT_LINE('<<<');
    END IF;

    RETURN lBucketList;
END getBucketList;
--------------------------------------------------------------------------------
FUNCTION    getObjectBlob
            (
                pBucket     IN      VARCHAR2,
                pObjectName IN      VARCHAR2,
                pPrefix     IN      VARCHAR2    DEFAULT NULL
            )
    RETURN  BLOB
/*  ----------------------------------------------------------------------------
* Routine Name: getObjectBlob
*
* Description:  Returns the contents of a specific file as a BLOB
*
* Arguments:    IN      pBucket         The name of the bucket containing the object
*               IN      pObjectName     The name of the object to be retrieved
*               IN      pPrefix         The folder name, known as a prefix in S3
*
* Returns:              BLOB             The contents of the object
----------------------------------------------------------------------------- */
AS
    dLocalTimestamp     DATE;
    vcCanonicalUri      VARCHAR2(128);
    vcDateString        VARCHAR2(8);
    vcISO_8601_Date     VARCHAR2(22);
    vcSignature         VARCHAR2(4000);
    vcURL               VARCHAR2(4000);
    vcPayloadHash       VARCHAR2(100);
    lBlob               BLOB;

BEGIN
    IF bDebug > DEBUG_OFF
    THEN
        DBMS_OUTPUT.PUT_LINE('>>>');
        DBMS_OUTPUT.PUT_LINE('================================================================================' );
        DBMS_OUTPUT.PUT_LINE('getObjectBlob' );
        DBMS_OUTPUT.PUT_LINE('Bucket Name: -    ' || pBucket );
        DBMS_OUTPUT.PUT_LINE('Object Name: -    ' || pObjectName );
        DBMS_OUTPUT.PUT_LINE('Optional Prefix - ' || pPrefix);
    END IF;

    dLocalTimestamp := localtimestamp;
    vcDateString    := TO_CHAR( dLocalTimestamp, DATE_FORMAT_URL );
    vcISO_8601_Date := vcReturnISO_8601_Date( dLocalTimestamp, TIME_ZONE );
    vcPayloadHash   := NULL_SHA256__HASH;
    vcCanonicalUri  := pPrefix || SLASH|| pObjectName;

    vcSignature :=  vcPrepareAwsData
                    (
                        pBucket             => pBucket,
                        pHttpMethod         => HTTP_GET_METHOD,
                        pCanonicalUri       => vcCanonicalUri,
                        pDate               => dLocalTimestamp,
                        pPayloadHash        => vcPayloadHash,
                        pURL                => vcURL
                    );

    lBlob   :=  bMakeRestRequest
                (
                    vcDateString,
                    vcSignature,
                    vcPayloadHash,
                    vcISO_8601_Date,
                    vcURL,
                    HTTP_GET_METHOD
                );

    IF bDebug > DEBUG_OFF
    then
        DBMS_OUTPUT.PUT_LINE('Object Length: - ' || DBMS_LOB.GETLENGTH( lBlob ));
        DBMS_OUTPUT.PUT_LINE('<<<');
    END IF;

    RETURN lBlob;

END getObjectBlob;
--------------------------------------------------------------------------------
PROCEDURE   getObjectList
            (
                pBucket         IN      VARCHAR2,
                pPrefix         IN      VARCHAR2    DEFAULT NULL,
                pObjectName     IN      VARCHAR2    DEFAULT NULL,
                pFilesRemaining     OUT BOOLEAN,
                pObjectList         OUT OBJECT_LIST
            )
/*  ----------------------------------------------------------------------------
* Routine Name: getObjectList
*
* Description:  Returns a list of all objects within a bucket.
*
* Note:         The maximum number of objects that are returned is 1000.
*               If the NUMBER of keys exceeds this you will get you will get TRUE
*               in the IsTruncated parameter in the returned CLOB

* Arguments:    IN      pBucket         The name of the bucket containing the object
*               IN      pPrefix         The folder name, known as a prefix in S3
*               IN      pObjectName     The name of a specific file if required
*
*
* Returns:              lObjectList     An array containing the list of buckets
----------------------------------------------------------------------------- */
AS
    dLocalTimestamp     DATE;
    vcDateString        VARCHAR2(8);
    vcISO_8601_Date     VARCHAR2(22);
    vcSignature         VARCHAR2(4000);
    vcUrl               VARCHAR2(4000);
    vcPayloadHash       VARCHAR2(100);
    vcFilesRemaining    VARCHAR2(10);
    vcQueryString       VARCHAR2(1000);
    iCount              BINARY_INTEGER := 0;
    lClob               CLOB;
    lXml                XMLTYPE;
    lObjectList         OBJECT_LIST;

    CURSOR  cExtractBucketContents
    IS
    SELECT
            extractValue( value(t), XML_KEY,            AWS_NAMESPACE_S3_FULL ) AS key,
            extractValue( value(t), XML_SIZE,           AWS_NAMESPACE_S3_FULL ) AS size_bytes,
            extractValue( value(t), XML_LAST_MODIFIED,  AWS_NAMESPACE_S3_FULL ) AS last_modified
    FROM
            TABLE( xmlsequence( lXml.extract( XML_LIST_BUCKET_CONTENTS, AWS_NAMESPACE_S3_FULL ))) t;

BEGIN
    IF bDebug > DEBUG_OFF
    THEN
        DBMS_OUTPUT.PUT_LINE('>>>');
        DBMS_OUTPUT.PUT_LINE('================================================================================' );
        DBMS_OUTPUT.PUT_LINE('getObjectList' );
        DBMS_OUTPUT.PUT_LINE('Bucket Name:-     ' || pBucket );
        DBMS_OUTPUT.PUT_LINE('Prefix:-          ' || pPrefix );
        DBMS_OUTPUT.PUT_LINE('Object Name:-     ' || pObjectName );
        DBMS_OUTPUT.PUT_LINE('Optional Prefix - ' || pPrefix);
    END IF;

    dLocalTimestamp     := localtimestamp;
    vcDateString        := TO_CHAR( dLocalTimestamp, DATE_FORMAT_URL );
    vcISO_8601_Date     := vcReturnISO_8601_Date( dLocalTimestamp, TIME_ZONE );
    vcPayloadHash       := NULL_SHA256__HASH;

    IF pPrefix IS NOT NULL
    THEN
        vcQueryString   := '?prefix=' || pPrefix;
    END IF;

    vcSignature :=  vcPrepareAwsData
                    (
                        pBucket             => pBucket,
                        pHttpMethod         => HTTP_GET_METHOD,
                        pCanonicalUri       => SLASH,
                        pQueryString        => vcQueryString,
                        pDate               => dLocalTimestamp,
                        pPayloadHash        => vcPayloadHash,
                        pURL                => vcUrl
                    );

    lClob   :=  cMakeRestRequest
                (
                    vcDateString,
                    vcSignature,
                    vcPayloadHash,
                    vcISO_8601_Date,
                    vcURL,
                    HTTP_GET_METHOD
                );

    vCheckForErrors( lClob );

    IF lClob IS NOT NULL
    THEN
        lXml := XMLTYPE( lClob );

        FOR rExtractBucketContents IN cExtractBucketContents
        LOOP
            iCount                              := iCount + 1;
            lObjectList(iCount).key             := rExtractBucketContents.key;
            lObjectList(iCount).size_bytes      := rExtractBucketContents.size_bytes;
            lObjectList(iCount).last_modified   := TO_DATE( rExtractBucketContents.last_modified, DATE_FORMAT_XML );
        END LOOP;
    END IF;

    lXml := lXml.extract( XML_LIST_TRUNCATED, AWS_NAMESPACE_S3_FULL );

    vcFilesRemaining := lXml.getStringVal;

    IF XML_TRUE = vcFilesRemaining
    THEN
        pFilesRemaining := TRUE;
    ELSE
        pFilesRemaining := FALSE;
    END IF;

    IF bDebug > DEBUG_OFF
    THEN
        DBMS_OUTPUT.PUT_LINE('List Truncated:-  '   || vcFilesRemaining );
        DBMS_OUTPUT.PUT_LINE('<<<');
    END IF;

    pObjectList := lObjectList;

END getObjectList;
--------------------------------------------------------------------------------
PROCEDURE   putObjectBlob
            (
                pBucket     IN      VARCHAR2,
                pBlob       IN      BLOB,
                pObjectKey  IN      VARCHAR2,
                pPrefix     IN      VARCHAR2    DEFAULT NULL
            )
/*  ----------------------------------------------------------------------------
* Routine Name: putObjectBlob
*
* Description:  Writes a the contents of the Blob to an object in an S3 Bucket.
*
* Arguments:    IN      pBucket         The name of the bucket containing the object
*               IN      pBlob           The Contents of the file as type RAW/BLOB
*               IN      pObjectKey      The name of the file
*               IN      pPrefix         The folder name, known as a prefix in S3
*
* Returns:              NULL
----------------------------------------------------------------------------- */
AS
    dLocalTimestamp     DATE;
    vcDateString        VARCHAR2(8);
    vcISO_8601_Date     VARCHAR2(22);

    vcCanonicalUri      VARCHAR2(100);
    vcSignature         VARCHAR2(4000);
    vcUrl               VARCHAR2(4000);
    vcPayloadHash       VARCHAR2(100);

    lClob               CLOB;
    lXml                XMLTYPE;

BEGIN
    IF bDebug > DEBUG_OFF
    THEN
        DBMS_OUTPUT.PUT_LINE('>>>');
        DBMS_OUTPUT.PUT_LINE('================================================================================' );
        DBMS_OUTPUT.PUT_LINE('putObjectBlob' );
        DBMS_OUTPUT.PUT_LINE('AWS Bucket -      ' || pBucket);
        DBMS_OUTPUT.PUT_LINE('File Name -       ' || pObjectKey );
        DBMS_OUTPUT.PUT_LINE('Object Length: -  ' || DBMS_LOB.GETLENGTH( pBlob ));
        DBMS_OUTPUT.PUT_LINE('Optional Prefix - ' || pPrefix);
    END IF;

    dLocalTimestamp     := localtimestamp;
    vcDateString        := TO_CHAR( dLocalTimestamp, DATE_FORMAT_URL );
    vcISO_8601_Date     := vcReturnISO_8601_Date( dLocalTimestamp, TIME_ZONE );
    vcCanonicalUri      := pPrefix || SLASH|| pObjectKey;
    vcPayloadHash       := vcAwsV4CryptoHash( pBlob );

    vcSignature :=  vcPrepareAwsData
                    (
                        pBucket             => pBucket,
                        pHttpMethod         => HTTP_PUT_METHOD,
                        pCanonicalUri       => vcCanonicalUri,
                        pDate               => dLocalTimestamp,
                        pPayloadHash        => vcPayloadHash,
                        pURL                => vcUrl
                    );

    lClob   :=  cMakeRestRequest
                (
                    vcDateString,
                    vcSignature,
                    vcPayloadHash,
                    vcISO_8601_Date,
                    vcURL,
                    HTTP_PUT_METHOD,
                    pBlob
                );

    vCheckForErrors( lClob );

    IF bDebug > DEBUG_OFF
    THEN
        DBMS_OUTPUT.PUT_LINE('<<<');
  END IF;

END putObjectBlob;

END aws_rds_to_s3_pkg;
/

SET SCAN ON
