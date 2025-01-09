#!/bin/bash

# Sync files from /bittensor_tmp to /root
echo "*** syncing files, please wait ***"
mv /bittensor_tmp/.bittensor/ /root/.bittensor/
mv /bittensor_tmp/.nvm/ /root/.nvm/
mv /bittensor_tmp/.npm/ /root/.npm/
echo "*** file sync complete ***"

export NVM_DIR="/root/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

pm2 list
pm2 resurrect
