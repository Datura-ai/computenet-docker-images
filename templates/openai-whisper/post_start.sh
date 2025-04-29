#!/bin/bash

echo "pod started"

# Handle SSH setup if PUBLIC_KEY is provided
if [[ -n $PUBLIC_KEY ]]
then
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    cd ~/.ssh
    echo $PUBLIC_KEY >> authorized_keys
    chmod 700 -R ~/.ssh
    cd /
    service ssh start
else
    echo "No PUBLIC_KEY provided. Skipping SSH setup."
fi

# Handle Jupyter Lab setup if JUPYTER_PASSWORD is provided
if [[ -n $JUPYTER_PASSWORD ]]
then
    cd /
    jupyter lab --allow-root --no-browser --port=8888 --ip=* \
        --ServerApp.terminado_settings='{"shell_command":["/bin/bash"]}' \
        --ServerApp.token=$JUPYTER_PASSWORD \
        --ServerApp.password='' \
        --ServerApp.disable_check_xsrf=True
else
    echo "No JUPYTER_PASSWORD provided. Skipping Jupyter Lab startup."

    cd /
    jupyter lab --allow-root --no-browser --port=8888 --ip=* \
        --ServerApp.terminado_settings='{"shell_command":["/bin/bash"]}' \
        --ServerApp.password='' \
        --ServerApp.disable_check_xsrf=True

    sleep infinity
fi