Pod::Spec.new do |s|
  s.name             = 'mw_printer'
  s.version          = '1.0.0'
  s.summary          = 'Impressao termica Bluetooth (BLE no iOS) com gerador ESC/POS.'
  s.description      = <<-DESC
Impressao termica Bluetooth para Flutter. No iOS usa BLE (CoreBluetooth).
                       DESC
  s.homepage         = 'https://github.com/'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'mw_printer' => 'mw_printer' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.frameworks       = 'CoreBluetooth'
  s.platform         = :ios, '12.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
