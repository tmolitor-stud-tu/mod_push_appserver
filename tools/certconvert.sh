
echo   This is a tool to convert p12 files genreated by OSX with the APNS  certificate and key  to the format desired by this module.  This expects the input  file to be named voip.p12. 
openssl pkcs12 -in voip.p12 -out voip.crt -nodes -nokeys -clcerts
openssl pkcs12 -in voip.p12 -out voip.key -nodes -nocerts -clcerts

