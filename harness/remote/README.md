docker run -d -p 2222:22 --rm my-ssh-server:latest

ssh-copy-id -p 2222 root@localhost
