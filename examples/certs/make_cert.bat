@echo off
REM Random Common Name so different deploys don't share a fingerprint.
REM OpenSSL 3.x is strict about argument order: the positional <num>
REM must follow all options (e.g. -out file, -hex), not precede them.
openssl rand -hex -out uid.txt 16
(set /p uid=)<uid.txt
openssl ecparam -out cakey.pem -name prime256v1 -genkey
openssl req -new -x509 -days 3650 -key cakey.pem -out cacert.pem -subj /CN=%uid%
openssl ecparam -out serverkey.pem -name prime256v1 -genkey
openssl req -new -key serverkey.pem -out servercert.pem -subj /CN=%uid%
openssl x509 -req -days 3650 -in servercert.pem -CA cacert.pem -CAkey cakey.pem -set_serial 01 -out servercert.pem
del uid.txt
pause
