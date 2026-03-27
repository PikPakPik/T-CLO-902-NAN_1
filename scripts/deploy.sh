#!/bin/bash
set -e

cd /home/ec2-user/kubequest

# Headlamp
helm upgrade --install headlamp headlamp/headlamp --namespace headlamp --create-namespace
kubectl apply -k infra/headlamp/