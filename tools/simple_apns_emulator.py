#!/usr/bin/env python3
import socket, ssl, time
import argparse
import random

parser = argparse.ArgumentParser(formatter_class=argparse.RawTextHelpFormatter, description="Simple APNS backend server emulator.\n")
parser.add_argument("-l", "--listen", metavar='HOSTNAME', help="Local hostname or IP to listen on (Default: 0.0.0.0 e.g. any)", default="0.0.0.0")
parser.add_argument("-p", "--port", metavar='PORT', type=int, help="Port to listen on (Default: 2195)", default=2195)
parser.add_argument("--probability", metavar='PROBABILITY', type=float, help="Error Probability (Default: 0.5)", default=0.5)
parser.add_argument("--cert", metavar='CERT', help="Certificate file to use (Default: localhost.pem)", default="localhost.pem")
parser.add_argument("--key", metavar='KEY', help="Key file to use (Default: localhost.pem)", default="localhost.pem")
args = parser.parse_args()

context = ssl.SSLContext(ssl.PROTOCOL_TLSv1_2)
context.load_cert_chain(certfile=args.cert, keyfile=args.key)

bindsocket = socket.socket()
bindsocket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
bindsocket.bind((args.listen, args.port))
bindsocket.listen(5)

print("Waiting for connections on %s:%d..." % (args.listen, args.port))
while True:
    newsocket, fromaddr = bindsocket.accept()
    sslsoc = context.wrap_socket(newsocket, server_side=True)
    print("Got new connection from %s..." % str(fromaddr))
    while True:
        request = sslsoc.read()
        if not len(request):
            break
        print("< %s" % str(request))
        if random.random() < args.probability:
            # the following simulates an error response of type 8 (invalid token)
            time.sleep(0.2)
            response = b'\x08\x08'+request[-8:-4]
            print("> %s" % str(response))
            sslsoc.write(response)
            sslsoc.close()
            break
    print("Connection was closed, waiting for new one...")
