#!/bin/sh

read -p '● Hostname: ' hstnm

sudo hostnamectl set-hostname hstnm

read -p "● Install portainer agent? (y/n) " answer
case ${answer:0:1} in
    y|Y )
        curl -sSL https://get.docker.com/ > /dev/null 2>&1 | CHANNEL=stable bash > /dev/null 2>&1
        
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

