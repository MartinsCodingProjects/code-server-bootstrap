# Issues while Testing:

## NVM and NVM-Version
- it says nvm version 22.23.33 in the current setup. I need nvm 24
- Had Isses installing/checking nvm from a working project:
  `
abc@036ee51f1bf5:/home/martin/dev-server/projects/pollkit$ source ~/.nvm/nvm.sh && nvm use
bash: /config/.nvm/nvm.sh: No such file or directory
abc@036ee51f1bf5:/home/martin/dev-server/projects/pollkit$ cd backend
abc@036ee51f1bf5:/home/martin/dev-server/projects/pollkit/backend$ source ~/.nvm/nvm.sh && nvm use
bash: /config/.nvm/nvm.sh: No such file or directory
abc@036ee51f1bf5:/home/martin/dev-server/projects/pollkit/backend$ cd ..
abc@036ee51f1bf5:/home/martin/dev-server/projects/pollkit$ cd frontend && npm ci
npm warn EBADENGINE Unsupported engine {
npm warn EBADENGINE   package: 'pollkit-frontend@0.0.0',
npm warn EBADENGINE   required: { node: '>=24' },
npm warn EBADENGINE   current: { node: 'v22.23.3', npm: '10.9.9' }
npm warn EBADENGINE }

added 414 packages, and audited 415 packages in 9s

150 packages are looking for funding
  run `npm fund` for details

found 0 vulnerabilities
abc@036ee51f1bf5:/home/martin/dev-server/projects/pollkit/frontend$ nvm install 24
bash: nvm: command not found
abc@036ee51f1bf5:/home/martin/dev-server/projects/pollkit/frontend$ cd ..
abc@036ee51f1bf5:/home/martin/dev-server/projects/pollkit$ nvm install 24
bash: nvm: command not found
abc@036ee51f1bf5:/home/martin/dev-server/projects/pollkit$ # Move back to the root of pollkit if you aren't there
cd /home/martin/dev-server/projects/pollkit

# Switch Node to v24
nvm use 24
bash: nvm: command not found
abc@036ee51f1bf5:/home/martin/dev-server/projects/pollkit$ nvm -v
bash: nvm: command not found
abc@036ee51f1bf5:/home/martin/dev-server/projects/pollkit$ export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
abc@036ee51f1bf5:/home/martin/dev-server/projects/pollkit$ export NVM_DIR="$HOME/.nvm"
abc@036ee51f1bf5:/home/martin/dev-server/projects/pollkit$ nvm -v
bash: nvm: command not found
abc@036ee51f1bf5:/home/martin/dev-server/projects/pollkit$ 
  ´

## Python 3.13 needed
- its 3.12 rn
