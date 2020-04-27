/* eslint-disable func-names */
/* eslint-disable no-console */
/* eslint-disable no-undef */
require('module-alias/register')
require('coffeescript/register')
// does what it says ...
packageJson = require('./package.json')
VieramaticPlatform = require('./lib/homebridge').VieramaticPlatform

module.exports = function(homebridge) {
  console.log(`homebridge API version: ${homebridge.version}`)
  console.log(`${packageJson.name} version: ${packageJson.version}`)
  console.log(`- Documentation: ${packageJson.homepage}`)
  console.log(`- Bugs and feedback: ${packageJson.bugs.url}\n`)
  Service = homebridge.hap.Service
  Characteristic = homebridge.hap.Characteristic
  Accessory = homebridge.platformAccessory
  homebridge.registerPlatform(packageJson.name, 'PanasonicVieraTV', VieramaticPlatform, true)
}
