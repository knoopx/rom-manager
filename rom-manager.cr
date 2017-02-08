#!/usr/bin/env crystal

require "xml"
require "zip"
require "admiral"
require "progress"

class Rom
  property :filename, :crc
  def initialize(@filename : String, @crc : String)
  end
end

class RomSet
  property :filename, :roms, :path

  def initialize(@filename : String, @roms : Array(Rom))
    @path = nil
  end

  def initialize(@filename : String, @roms : Array(Rom), @path : String)
  end

  def self.load(path)
    roms = [] of Rom

    Zip::File.open(path ) do |zip|
       zip.entries.each do |entry|
         entry.open do |io|
           roms << Rom.new(entry.filename, Zlib.crc32(io.gets_to_end).to_s(16))
         end
       end
    end

    RomSet.new(File.basename(path), roms, path)
  end
end

class Dat
  def self.parse(file)
    romsets = [] of RomSet
    xml = XML.parse(File.read(file))
    xml.xpath_nodes("//game").each do |game|
      roms = game.xpath_nodes(".//rom").select{|rom| rom["crc"]? }.map { |rom| Rom.new(rom["name"], rom["crc"]) }
      romsets << RomSet.new("#{game["name"]}.zip", roms)
    end
    romsets
  end
end

# alias RomSet = NamedTuple(filename: String, roms: Array(Rom))

def find_romsets(paths : Array(String))
   paths.map{|path| Dir.glob(File.join(path, "*.zip")) }.flatten.map{ |f| File.expand_path(f) }
end

def scan_romsets(files)
  bar = ProgressBar.new
  bar.total = files.size
  index = [] of RomSet

  files.each do |file|
    begin
      index << RomSet.load(file)
    rescue e
      puts e
    end
    bar.inc
  end

  index
end

def index_romsets(romsets)
  index = {} of String => Tuple(Rom, String)
  romsets.each do |romset|
    romset.roms.each do |rom|
      index[rom.crc] = {rom, romset.path.to_s}
    end
  end
  index
end

def rebuild_romset(romset, sources, target_dir)
  puts romset.filename
  target_path = File.join(target_dir, romset.filename)

  File.open(target_path, "w") do |io|
    Zip::Writer.open(io) do |target_zip|
      sources.group_by{ |_, path| path }.each do |source_file, tuples|
        Zip::File.open(source_file) do |source_zip|
          tuples.each do |source_rom, _|
            romset.roms.each do |target_rom|
              if (target_rom.crc == source_rom.crc)
                if entry = source_zip.entries.find{|e| e.filename == source_rom.filename }
                  puts "  #{File.join(source_file, source_rom.filename)} => #{File.join(target_path, target_rom.filename)}"
                  entry.open { |io|  target_zip.add(target_rom.filename, io) }
                end
              end
            end
          end
        end
      end
    end
  end
end

def rebuild_romsets(dat, index, target_dir)
  bar = ProgressBar.new
  bar.total = dat.size
  dat.each do |romset|
    sources = romset.roms.map{ |rom| index[rom.crc]? }.compact
    if (sources.size == romset.roms.size)
        rebuild_romset(romset, sources, target_dir)
    end
    bar.inc
  end
end

class RomManager < Admiral::Command
  class RebuildCommand < Admiral::Command
    define_help
    define_flag rom_set_dir : Array(String), required: true
    define_argument dat_file, required: true
    define_argument target_dir, required: true

    def run()
      target_dir = File.expand_path(arguments.target_dir)
      raise "Target dir does not exist: #{target_dir}" unless File.directory?(target_dir)
      puts "Loading dat file..."
      dat = Dat.parse(arguments.dat_file)

      puts "Finding romsets..."
      romsets = scan_romsets(find_romsets(flags.rom_set_dir))

      puts "Indexing roms..."
      index = index_romsets(romsets)

      puts "Rebuilding romsets... (#{index.keys.uniq.size} roms found)"
      rebuild_romsets(dat, index, target_dir)
    end
  end

  define_help
  register_sub_command rebuild, RebuildCommand, "Rebuild romsets"

  def run
    puts help
  end
end

RomManager.run
