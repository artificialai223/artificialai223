#!/bin/sh

read -p '● Hostname: ' hstnm

sudo hostnamectl set-hostname hstnm

read -p "● Install portainer agent? (y/n) " answer
case ${answer:0:1} in
    y|Y )
        curl -sSL https://get.docker.com/ | CHANNEL=stable bash
        
        docker run -d -p 9001:9001 --name portainer_agent --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v /var/lib/docker/volumes:/var/lib/docker/volumes portainer/agent:2.11.1 > /dev/null 2>&1
        echo "● Portainer agent installed."
        echo "● Use the server IP with the port 9001 to connect to this agent."
    ;;
esac


# IPTables
sudo iptables -P INPUT ACCEPT
sudo iptables -P OUTPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables -F

iptables --flush

echo "● IPTables cleared"

# Sync netdata

sudo apt install curl -y

curl https://my-netdata.io/kickstart.sh > /tmp/netdata-kickstart.sh && sh /tmp/netdata-kickstart.sh --claim-token f0pegBC3X81JGWCjyckpQ86aNUpjG_UU6bn7zjg2a39nAR8q0YX6YzJc_qnH_7XzxVXxPZ7Oa0qBq7SULEBqfa7ldlpMsBc4dbe8eLGYnd80HolrFr-BY4Ry4exRwSiF--UTimc --claim-rooms 4e447620-695c-4704-a1e2-513f3bbaa8b0 --claim-url https://app.netdata.cloud

echo "● Netdata synced"

