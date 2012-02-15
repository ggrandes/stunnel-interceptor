#!/bin/bash

# File stdin format:
#
# basePort
# interceptedIP	interceptedPort
# interceptedIP	interceptedPort
# interceptedIP	interceptedPort
# interceptedIP	interceptedPort
# interceptedIP	interceptedPort
# ...
#
# Sample:
# 9000	10000
# 123.48.12.122	443
# 123.48.12.128	143
# 123.43.12.112	587

set -e

read localBase
localBasePort1="$(cut -f 1 <<< "$localBase")"
localBasePort2="$(cut -f 2 <<< "$localBase")"
stunnelConfigDir="$(mktemp -d)"
cd $stunnelConfigDir

echo "[+] Killing previous stunnels."
killall -9 stunnel || true

echo "[+] Configuring iptables and forwarding."
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -F

echo "[+] Generating wildcard certificate."
subj="
C=CR
ST=ST
O=ACME
localityName=TOWN
commonName=*
organizationalUnitName=INTERCEPT
emailAddress=$(whoami)@$(uname -n)"
mkdir -p demoCA/{certs,crl,newcerts,private}
echo 01 > demoCA/serial
touch demoCA/index.txt
openssl req -new -x509 -keyout demoCA/private/cakey.pem -out demoCA/cacert.pem -days 3652 -passout pass:1234 -subj "$(tr "\n" "/" <<< "$subj")"
openssl req -new -keyout ./wildcard.req -out ./wildcard.req -days 3652 -passout pass:1234 -passin pass:1234 -subj "$(tr "\n" "/" <<< "$subj")"
echo -e "y\ny"|openssl ca  -passin pass:1234 -policy policy_anything -out wildcard.crt -infiles wildcard.req
openssl rsa -passin pass:1234 < wildcard.req > wildcard.key
cat wildcard.crt wildcard.key > wildcard.pem
openssl pkcs12 -passin pass:1234 -passout pass:1234 -export -in demoCA/cacert.pem -inkey demoCA/private/cakey.pem -out cacert.p12

counter=0
while read line; do
	remoteIP="$(cut -f 1 <<< "$line")"
	remotePort="$(cut -f 2 <<< "$line")"
	localPort1="$(($localBasePort1 + $counter))"
	localPort2="$(($localBasePort2 + $counter))"
	serverConfig="server-$counter.conf"
	clientConfig="client-$counter.conf"
	
	echo "[+] Configuring iptables to redirect $remoteIP:$remotePort <--> incoming:$localPort1"
	iptables -t nat -A PREROUTING -p TCP --destination "$remoteIP" --dport "$remotePort" -j REDIRECT --to-port "$localPort1"
	
	echo "[+] Writing stunnel config for incoming:$localPort1 <--> localhost:$localPort2"
	echo "	foreground=no
		service=stunnel
		cert=wildcard.pem
		[server]
		accept=0.0.0.0:$localPort1
		connect=127.0.0.1:$localPort2" > "$serverConfig"
	echo "	foreground=no
		client=yes
		[client]
		accept=127.0.0.1:$localPort2
		connect=$remoteIP:$remotePort" > "$clientConfig"
	
	echo "[+] Starting server-$counter"
	stunnel "$serverConfig"
	echo "[+] Starting client-$counter"
	stunnel "$clientConfig"
	
	counter="$(($counter + 1))"
done

cd - > /dev/null
#rm -rf "$stunnelConfigDir"
echo $stunnelConfigDir
