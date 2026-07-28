import { defineConfig } from 'vitepress'

export default defineConfig({
  ignoreDeadLinks: true,
  base: '/azurelocal-ztp/',
  title: "Azure Local ZTP",
  description: "Governed centrally by HCS Platform Engineering standards",
  themeConfig: {
    nav: [{"link":"/","text":"Home"},{"link":"/server-preparation","text":"Server preparation"},{"link":"/azure-portal-provisioning","text":"Azure portal provisioning"},{"link":"/single-node-s2d-deployment","text":"Single-node S2D deployment"},{"link":"/automation-pipelines","text":"Automation pipelines"}],
    sidebar: [{"link":"/","text":"Home"},{"link":"/server-preparation","text":"Server preparation"},{"link":"/azure-portal-provisioning","text":"Azure portal provisioning"},{"link":"/single-node-s2d-deployment","text":"Single-node S2D deployment"},{"link":"/automation-pipelines","text":"Automation pipelines"}],
    socialLinks: [
      { icon: 'github', link: 'https://github.com/AzureLocal/azurelocal-ztp' }
    ],
    footer: {
      message: 'Released under the MIT License.',
      copyright: 'Copyright © Hybrid Cloud Solutions & AzureLocal'
    }
  }
})




