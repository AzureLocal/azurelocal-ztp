import { defineConfig } from 'vitepress'

export default defineConfig({
  ignoreDeadLinks: true,
  base: '/azurelocal-ztp/',
  title: "Azure Local ZTP",
  description: "Governed centrally by HCS Platform Engineering standards",
  themeConfig: {
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Design', link: '/architecture' },
      { text: 'Operator guide', link: '/operator-guide' },
      { text: 'Pipelines', link: '/automation-pipelines' },
      { text: 'Troubleshooting', link: '/troubleshooting' }
    ],
    sidebar: [
      { text: 'Home', link: '/' },
      {
        text: 'Zero-touch provisioning',
        items: [
          { text: 'Design and architecture', link: '/architecture' },
          { text: 'Operator guide', link: '/operator-guide' },
          { text: 'Environment file reference', link: '/environment-file' },
          { text: 'Running from a pipeline', link: '/automation-pipelines' },
          { text: 'Troubleshooting and known issues', link: '/troubleshooting' }
        ]
      },
      {
        text: 'How it works',
        items: [
          { text: 'Orchestrator reference', link: '/automated-bootstrap' },
          { text: 'Bootstrap media and the OEM SBE', link: '/bootstrap-media-and-sbe' },
          { text: 'Redfish virtual USB and vouchers', link: '/redfish-virtual-usb-vouchers' },
          { text: 'Azure provisioning from vouchers', link: '/azure-provisioning-vouchers' }
        ]
      },
      {
        text: 'Legacy and other guides',
        collapsed: true,
        items: [
          { text: 'Server preparation (superseded)', link: '/server-preparation' },
          { text: 'Azure portal provisioning (superseded)', link: '/azure-portal-provisioning' },
          { text: 'Single-node S2D deployment', link: '/single-node-s2d-deployment' }
        ]
      }
    ],
    socialLinks: [
      { icon: 'github', link: 'https://github.com/AzureLocal/azurelocal-ztp' }
    ],
    footer: {
      message: 'Released under the MIT License.',
      copyright: 'Copyright © Hybrid Cloud Solutions & AzureLocal'
    }
  }
})




