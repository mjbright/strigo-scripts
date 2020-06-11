#!/bin/bash

CUSTOM_CSS_URL=${CUSTOM_CSS_URL:-https://raw.githubusercontent.com/mjbright/kubelab/master/custom.css}

APT_INSTALLS() {
    #sudo apt-get update && sudo apt-get upgrade -y && sudo apt-get install -y tmux curl vim && sudo apt-get clean && sudo apt-get autoclean
    sudo apt-get update
    sudo apt-get upgrade -y
    sudo apt-get install -y tmux curl vim python3-pip
}

PIP_INSTALLS() {
    sudo python3 -m pip install --upgrade pip
    sudo python3 -m pip install setuptools
    sudo python3 -m pip install pick ppretty
    sudo python3 -m pip install RISE
    sudo python3 -m pip install kubernetes
    sudo python3 -m pip install jupyter_nbextensions_configurator
    sudo python3 -m pip install --no-cache-dir bash_kernel
}

ENABLE_JUPYTER_BASH() {
    CMD="sudo jupyter nbextensions_configurator enable --system"
    echo; echo "---- $CMD"; $CMD

    CMD="sudo -u $END_USER HOME=/home/$END_USER python3 -m bash_kernel.install"
    echo; echo "---- $CMD"; $CMD
    echo
}

INSTALL_CUSTOM_CSS() {
    CUSTOM_CSS=/home/$END_USER/.jupyter/custom/custom.css
    mkdir -p /home/$END_USER/.jupyter/custom/

    wget -O $CUSTOM_CSS $CUSTOM_CSS_URL
    ls -al $CUSTOM_CSS
    chown -R $END_USER:$END_USER /home/$END_USER/.jupyter/
}

END_USER=${USERS% *}
END_USER=${END_USER%:*}
[ -z "$END_USER" ] && END_USER=ubuntu

#echo $END_USER

APT_INSTALLS
PIP_INSTALLS
ENABLE_JUPYTER_BASH
INSTALL_CUSTOM_CSS

cat > /tmp/jupyter.sh <<EOF
#!/bin/bash

if [[ "\$1" = "-fg" ]]; then
    shift
else
    ( \$0 -fg "\$@" </dev/null &>/dev/null & )
    exit
fi

exec > /tmp/jupyter.log 2>&1
echo "Logging jupyter output to /tmp/jupyter.log"

export HOME=/home/$END_USER
cd

while true; do
    #jupyter notebook --port 8888 --ip=0.0.0.0 --allow-root --no-browser
    jupyter notebook --port 8888 --ip=127.0.0.1 --allow-root --no-browser
done

EOF

chmod a+x /tmp/jupyter.sh
echo "Starting Jupyter using: /tmp/jupyter.sh"
echo "Look for token in:   /tmp/jupyter.log"

CMD="sudo -u $END_USER HOME=/home/$END_USER /tmp/jupyter.sh"
echo; echo "---- $CMD"; $CMD

echo "Setup ssh tunnel to open port $(ec2metadata --public-host):8888 to localhost:8888"

exit 0

