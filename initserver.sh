#!/bin/bash

read -p '● Hostname: ' hstnm

sudo hostnamectl set-hostname hstnm
clear
read -p "● Install portainer agent? (y/n) " answer
clear
case ${answer:0:1} in
    y|Y )
        echo "● Installing docker..."
        curl -sSL https://get.docker.com/ | CHANNEL=stable bash
        clear
        echo "● Docker installed"
        echo "● Installing portainer agent..."
        
        docker run -d -p 9001:9001 --name portainer_agent --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v /var/lib/docker/volumes:/var/lib/docker/volumes portainer/agent:2.11.1
        clear
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

clear

echo "● IPTables records cleared"

