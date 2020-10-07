
### make shortcut to tool #################################################
#def objexporter()
#  Sketchup.active_model.select_tool(OBJexporter.new())
#end

### add menu item etc #####################################################
unless file_loaded?(__FILE__)
  UI.menu("File").add_item("OBJexporter...") {
    #require 'objexporter/OBJexporter'

    pluginDir = File.dirname(__FILE__)
    fileName = File.join(pluginDir, '/objexporter/OBJexporter.rb')
    load(fileName)

    OBJexporter.new()
  }
end

file_loaded(__FILE__)
