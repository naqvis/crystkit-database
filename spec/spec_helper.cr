require "spec"
require "file_utils"
require "../src/crystkit-database"

module SpecHelpers
  def self.with_temp_dir(& : String ->)
    dir = File.tempname("crystkit_database_spec")
    Dir.mkdir_p(dir)
    begin
      yield dir.gsub('\\', '/')
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end
end
