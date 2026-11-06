import { defineConfig } from 'vitepress'

// The sidebar is this site's only page navigation. The top bar carries site-wide links only
// (azurelocal.cloud, the sibling tools, GitHub), so it doesn't repeat the sidebar.
const tools = [
  {
    text: 'Plan and assess',
    items: [
      { text: 'Surveyor', link: 'https://azurelocal.cloud/azurelocal-surveyor/' },
      { text: 'Ranger', link: 'https://azurelocal.cloud/azurelocal-ranger/' }
    ]
  },
  {
    text: 'Deploy',
    items: [
      { text: 'Beacon', link: 'https://azurelocal.cloud/azurelocal-beacon/' },
      { text: 'Zero Touch Provisioning (ZTP)', link: 'https://azurelocal.cloud/azurelocal-ztp/' },
      { text: 'Sonar', link: 'https://azurelocal.cloud/azurelocal-sonar/' },
      { text: 'Toolkit', link: 'https://azurelocal.cloud/azurelocal-toolkit/' }
    ]
  },
  {
    text: 'Operate and test',
    items: [
      { text: 'Load Testing Framework', link: 'https://azurelocal.cloud/azurelocal-loadtools/' },
      { text: 'S2D Cartographer', link: 'https://azurelocal.cloud/azurelocal-s2d-cartographer/' }
    ]
  }
]

export default defineConfig({
  ignoreDeadLinks: false,
  base: '/azurelocal-ztp/',
  title: 'Azure Local ZTP',
  description: 'Zero-touch provisioning for Azure Local: from bare machines to nodes ready for cluster Validate.',
  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: '/azurelocal-ztp/assets/images/azurelocal-ztp-icon.svg' }]
  ],
  themeConfig: {
    logo: '/assets/images/azurelocal-ztp-icon.svg',
    siteTitle: 'Azure Local ZTP',
    nav: [
      { text: 'azurelocal.cloud', link: 'https://azurelocal.cloud/' },
      { text: 'Tools', items: tools }
    ],
    sidebar: [
      {
        text: 'Get started',
        items: [
          { text: 'Overview', link: '/overview' },
          { text: 'Operator guide', link: '/operator-guide' },
          { text: 'Monitoring a run', link: '/monitoring' },
          { text: 'Environment file reference', link: '/environment-file' }
        ]
      },
      {
        text: 'Design',
        items: [
          { text: 'Design and architecture', link: '/architecture' },
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
    outline: { level: [2, 3] },
    search: { provider: 'local' },
    socialLinks: [
      { icon: 'github', link: 'https://github.com/AzureLocal/azurelocal-ztp' }
    ],
    editLink: {
      pattern: 'https://github.com/AzureLocal/azurelocal-ztp/edit/main/docs/:path',
      text: 'Edit this page on GitHub'
    },
    footer: {
      message: 'Released under the MIT License.',
      copyright: 'Copyright © Hybrid Cloud Solutions & AzureLocal'
    }
  }
})
