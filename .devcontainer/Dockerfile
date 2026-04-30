FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Install Azure CLI
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash

# Install Terraform
RUN wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
RUN echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com jammy main" | tee /etc/apt/sources.list.d/hashicorp.list
RUN apt update && apt install -y terraform

# Install Bicep CLI
RUN curl -Lo bicep https://github.com/Azure/bicep/releases/latest/download/bicep-linux-x64
RUN chmod +x ./bicep
RUN mv ./bicep /usr/local/bin/bicep

# Install other tools
RUN apt install -y \
    ansible \
    ansible-lint \
    jq \
    git \
    curl \
    wget \
    unzip

# Install Node.js for scripts
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
RUN apt install -y nodejs

# Install Asciidoctor for docs
RUN apt install -y asciidoctor

# Clean up
RUN apt clean && rm -rf /var/lib/apt/lists/*