#!/usr/bin/env ruby
# Minimal static file + JSON API server so shared state persists on the backend
# instead of per-browser localStorage.
require 'webrick'
require 'json'
require 'fileutils'

ROOT = File.expand_path(__dir__)
STATE_FILE = File.join(ROOT, 'server_state.json')
PORT = (ENV['PORT'] || 8000).to_i

def read_state
  return { 'imaginaryAxisRevealed' => false } unless File.exist?(STATE_FILE)
  JSON.parse(File.read(STATE_FILE))
rescue JSON::ParserError
  { 'imaginaryAxisRevealed' => false }
end

def write_state(state)
  File.write(STATE_FILE, JSON.generate(state))
end

class ImaginaryAxisStateServlet < WEBrick::HTTPServlet::AbstractServlet
  def do_GET(req, res)
    res['Content-Type'] = 'application/json'
    res.body = JSON.generate(read_state)
  end

  def do_POST(req, res)
    state = read_state
    state['imaginaryAxisRevealed'] = true
    write_state(state)
    res['Content-Type'] = 'application/json'
    res.body = JSON.generate(state)
  end
end

server = WEBrick::HTTPServer.new(Port: PORT, DocumentRoot: ROOT)
server.mount('/api/imaginary-axis-state', ImaginaryAxisStateServlet)

trap('INT') { server.shutdown }
puts "Serving #{ROOT} at http://localhost:#{PORT}"
server.start
