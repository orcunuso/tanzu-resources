#!/bin/bash
# This script is used to add a proxy to Containerd service
# and copies CA certificate of harbor registry
# in a vSphere with Kubernetes Tanzu Kubernetes 
# cluster. After adding the proxy, it will restart
# the Containerd service in every node.
#
# USAGE: 00-tkg-script.sh $name-cluster $namespace $registry-server
# 
# Dependencies: curl, jq, sshpass

SV_IP='' #VIP for the Supervisor Cluster
VC_IP='' #URL for the vCenter
VC_ADMIN_USER='administrator@vsphere.local' #User for the Supervisor Cluster
VC_ADMIN_PASSWORD='Password' #Password for the Supervisor Cluster user
VC_ROOT_PASSWORD='Password!' #Password for the root VCSA user

TKG_CLUSTER_NAME=$1 # Name of the TKG cluster
TKG_CLUSTER_NAMESPACE=$2 # Namespace where the TKG cluster is deployed
URL_REGISTRY=$3 # URL or IP of the Registry to be added 
URL_REGISTRY_TRIM=$(echo "${URL_REGISTRY}" | sed 's~http[s]*://~~g') # Sanitize registry URL to remove http/https

logerr() { echo "$(date) ERROR: $@" 1>&2; }
loginfo() { echo "$(date) INFO: $@" ;}

if [[ -z "$1" || -z "$2" || -z "$3" ]]
  then
    logerr "Invalid arguments. Exiting..."
    logerr "USAGE: 00-tkg-script.sh tkc-cluster-name namespace-name registry-server"
    exit 2
fi

# Exit the script if the supervisor cluster is not up
if [ $(curl -m 15 -k -s -o /dev/null -w "%{http_code}" https://"${SV_IP}") -ne "200" ]; then
    logerr "Supervisor cluster not ready. Exiting..."
    exit 2
fi

# If the supervisor cluster is ready, get the token for TKG cluster
loginfo "Supervisor cluster is ready!"
loginfo "Getting TKC Kubernetes API token..."

# Get the TKG Kubernetes API token by login into the Supervisor Cluster
TKC_API=$(curl -XPOST -s -u "${VC_ADMIN_USER}":"${VC_ADMIN_PASSWORD}" https://"${SV_IP}":443/wcp/login -k -d '{"guest_cluster_name":"'"${TKG_CLUSTER_NAME}"'", "guest_cluster_namespace":"'"${TKG_CLUSTER_NAMESPACE}"'"}' -H "Content-Type: application/json" | jq -r '.guest_cluster_server')
TOKEN=$(curl -XPOST -s -u "${VC_ADMIN_USER}":"${VC_ADMIN_PASSWORD}" https://"${SV_IP}":443/wcp/login -k -d '{"guest_cluster_name":"'"${TKG_CLUSTER_NAME}"'", "guest_cluster_namespace":"'"${TKG_CLUSTER_NAMESPACE}"'"}' -H "Content-Type: application/json" | jq -r '.session_id')

# Verify if the token is valid
if [ $(curl -k -s -o /dev/null -w "%{http_code}" https://"${TKC_API}":6443/ --header "Authorization: Bearer "${TOKEN}"") -ne "200" ]
then
      logerr "TKC Kubernetes API token is not valid. Exiting..."
      exit 2
else
      loginfo "TKC Kubernetes API token is valid!"
fi

#Get the list of nodes in the cluster
curl -XGET -k --fail -s https://"${TKC_API}":6443/api/v1/nodes --header 'Content-Type: application/json' --header "Authorization: Bearer "${TOKEN}"" >> /dev/null
if [ $? -eq 0 ] ;
then      
      loginfo "Getting the IPs of the nodes in the cluster..."
      curl -XGET -k --fail -s https://"${TKC_API}":6443/api/v1/nodes --header 'Content-Type: application/json' --header "Authorization: Bearer "${TOKEN}"" | jq -r '.items[].status.addresses[] | select(.type=="InternalIP").address' > ./ip-nodes-tkg
      loginfo "The nodes IPs are: "$(column ./ip-nodes-tkg | sed 's/\t/,/g')""
else
      logerr "There was an error processing the IPs of the nodes. Exiting..."
      exit 2
fi

#SSH into vCenter to get credentials for the supervisor cluster master VMs
sshpass -p "${VC_ROOT_PASSWORD}" ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q root@"${VC_IP}" com.vmware.shell /usr/lib/vmware-wcp/decryptK8Pwd.py > ./sv-cluster-creds 2>&1
if [ $? -eq 0 ] ;
then      
      loginfo "Connecting to the vCenter to get the supervisor cluster VM credentials..."
      SV_MASTER_IP=$(cat ./sv-cluster-creds | sed -n -e 's/^.*IP: //p')
      SV_MASTER_PASSWORD=$(cat ./sv-cluster-creds | sed -n -e 's/^.*PWD: //p')
      loginfo "Supervisor cluster master IP is: "${SV_MASTER_IP}""
else
      logerr "There was an error logging into the vCenter. Exiting..."
      exit 2
fi

#Get Supervisor Cluster token to get the TKC nodes SSH Password
loginfo "Getting Supervisor Cluster Kubernetes API token..."
SV_TOKEN=$(curl -XPOST -s --fail -u "${VC_ADMIN_USER}":"${VC_ADMIN_PASSWORD}" https://"${SV_IP}":443/wcp/login -k -H "Content-Type: application/json" | jq -r '.session_id')

# Verify if the Supervisor Cluster token is valid
# Health check in /api/v1 (Supervisor Cluster forbids accessing / directly (TKC cluster allows it))
if [ $(curl -k -s -o /dev/null -w "%{http_code}" https://"${SV_IP}":6443/api/v1 --header "Authorization: Bearer "${SV_TOKEN}"") -ne "200" ]
then
      logerr "Supervisor Cluster Kubernetes API token is not valid. Exiting..."
      exit 2
else
      loginfo "Supervisor Cluster Kubernetes API token is valid!"
fi

# Get the TKC nodes SSH private key from the Supervisor Cluster
curl -XGET -k --fail -s https://"${SV_IP}":6443/api/v1/namespaces/"${TKG_CLUSTER_NAMESPACE}"/secrets/"${TKG_CLUSTER_NAME}"-ssh --header 'Content-Type: application/json' --header "Authorization: Bearer "${SV_TOKEN}"" >> /dev/null 
if [ $? -eq 0 ] ;
then      
      loginfo "Getting the TKC nodes SSH private key from the supervisor cluster..."
      curl -XGET -k --fail -s https://"${SV_IP}":6443/api/v1/namespaces/"${TKG_CLUSTER_NAMESPACE}"/secrets/"${TKG_CLUSTER_NAME}"-ssh --header 'Content-Type: application/json' --header "Authorization: Bearer "${SV_TOKEN}"" | jq -r '.data."ssh-privatekey"' | base64 -d > ./tkc-ssh-privatekey
      #Set correct permissions for TKC SSH private key
      chmod 600 ./tkc-ssh-privatekey
      loginfo "TKC SSH private key retrieved successfully!"
else
      logerr "There was an error getting the TKC nodes SSH private key. Exiting..."
      exit 2
fi

# Transfer the TKC nodes SSH private key to the Supervisor Cluster Master VM
loginfo "Transferring the TKC nodes SSH private key to the supervisor cluster VM..."
sshpass -p ${SV_MASTER_PASSWORD} scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ./tkc-ssh-privatekey root@"${SV_IP}":./tkc-ssh-privatekey-${TKG_CLUSTER_NAME} >> /dev/null
if [ $? -eq 0 ] ;
then      
      loginfo "TKC SSH private key transferred successfully!"
else
      logerr "There was an error transferring the TKC nodes SSH private key. Exiting..."
      exit 2
fi

# SSH to every node and modify proxy configurations and trusted certificates on the nodes
export SSHPASS="${SV_MASTER_PASSWORD}"

while read -r IPS_NODES_READ;
do
loginfo "Adding proxy and CA certificate to the node '"${IPS_NODES_READ}"'..."
sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q -t root@"${SV_IP}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ./tkc-ssh-privatekey-${TKG_CLUSTER_NAME} -t -q vmware-system-user@"${IPS_NODES_READ}" << EOF
sudo -i
mkdir -p /etc/systemd/system/containerd.service.d
rm -rf /etc/systemd/system/containerd.service.d/http-proxy.conf

cat << EOF1 > /etc/systemd/system/containerd.service.d/http-proxy.conf.new
[Service]
Environment="HTTP_PROXY=proxyserver:port"
Environment="HTTPS_PROXY=proxyserver:port"
Environment="NO_PROXY=10.0.0.0/8,localhost,127.0.0.1"
EOF1

if [[ -s /etc/systemd/system/containerd.service.d/http-proxy.conf.new ]]; then mv /etc/systemd/system/containerd.service.d/http-proxy.conf.new /etc/systemd/system/containerd.service.d/http-proxy.conf ; else exit 2; fi

############# Add CA certificate of Harbor Registry to the nodes
rm -rf /etc/ssl/certs/regcert.pem

cat << EOF1 > /etc/ssl/certs/regcert.pem
-----BEGIN CERTIFICATE-----
MIIEGzCCAwOgAwIBAgIJANXuxNTJdQBRMA0GCSqGSIb3DQEBCwUAMIGYMQswCQYD
VQQDDAJDQTEVMBMGCgmSJomT8ixkARkWBXRhbnp1MRMwEQYKCZImiZPyLGQBGRYD
cG9jMQswCQYDVQQGEwJVUzETMBEGA1UECAwKQ2FsaWZvcm5pYTEeMBwGA1UECgwV
eWFudmNzMDEudHVya2NlbGwudGdjMRswGQYDVQQLDBJWTXdhcmUgRW5naW5lZXJp
bmcwHhcNMjAxMjE1MTA0MTM1WhcNMzAxMjEzMTA0MTM1WjCBmDELMAkGA1UEAwwC
Q0ExFTATBgo.....................................8ixkARkWA3BvYzEL
MAkGA1UEBhM.                                   .BgNVBAoMFXlhbnZj
czAxLnR1cmt.  Paste your CA certificate        .Z2luZWVyaW5nMIIB
IjANBgkqhki.                                   .pswXL/Cadze5RJmc
eTNkRuOCXtx.....................................9KpvYDciz4+Pmlo2
IXS9ePi5Fa8ByvNxCw3BnL4aM6agMuh/c4cJEhHwc/JfhyuRF02QTVwtOdKF/UqZ
A93nEudIo2tuUQPPM6rbwOPzInWDUAtVh3XdzbX5CT1vRm6vStGyercfynlH2VsV
gwdd+GbyE3MDgXufGzEEjaFcKkKXOOFLiW2XhC7OTRYUKVu/L+IzMI8IjdwAW2Qb
7uq8df9qahtgb9wo1N4oYVZLfCjWaHoqH5WvOZz4Eq3tLWPFE4XPzqNPZeY+gwID
AQABo2YwZDAdBgNVHQ4EFgQUympnlbrFWPMe5bk2kBs5b03yA6EwHwYDVR0RBBgw
FoEOZW1haWxAYWNtZS5jb22HBH8AAAEwDgYDVR0PAQH/BAQDAgEGMBIGA1UdEwEB
/wQIMAYBAf8CAQAwDQYJKoZIhvcNAQELBQADggEBANycZee0dJzMTihuga5r4MZ0
rvdW7fFei+dsim8KjwqAF66zcjXAkwSJt8tW5JYqlKijWAeJRa9JtAOTONSlUfeC
zaY1tPWrLhO7KC38PeigjM/gqj6mC4WSqnkmCJXmla4YuazmpqzxchGgVs24s+Gg
ebBnpueQ2pcffiYcObt6fKhQN4YQo75X63AMZHB42pDCTxKcfA0UTLMwaiaD8zhO
/IebIXUdJNbCv/BZGlwiYON4B8HM/5RtHVMo/5JqNHHuBrXBKHoEVeX33q2mvu/0
uCcD8tY69tkr/qKDIeD9JRDzJgL41mZmCac9Xx1UX2c03E6QqUOH6w+dcFjBn8Q=
-----END CERTIFICATE-----
EOF1
/usr/bin/rehash_ca_certificates.sh > /dev/null 2>&1

# Restart containerd services on the nodes
systemctl daemon-reload
systemctl stop containerd
systemctl start containerd

EOF
if [ $? -eq 0 ] ;
then  
      loginfo "Proxy and CA certificate added successfully!"
else
      logerr "There was an error. Exiting..."
      exit 2
fi
done < "./ip-nodes-tkg"

# Cleaning up
loginfo "Cleaning up temporary files..."
rm -rf ./tkc-ssh-privatekey
rm -rf ./sv-cluster-creds
rm -rf ./ip-nodes-tkg
