require 'json'
require 'socket'
require 'bundler'
Bundler.require(:default, :default)

CONFIG = JSON.parse(File.read(File.expand_path('../config.json', __FILE__)))
Thread.abort_on_exception = true
Thread.report_on_exception = true

def cli_scan
  CONFIG['ports']&.each do |port|
    socket = TCPSocket.new('localhost', port)
  rescue Errno::ECONNREFUSED => e
    $stderr.puts sprintf('SSH port %d not ready yet!', port)
    retry
  else
    socket.close
    $stderr.puts sprintf('SSH Port %d is ready!', port)
  end

  $stderr.puts 'Ready to go!'
  sleep 1
end

def fiddle_support_malloc_free?
  version = defined?(Fiddle::VERSION) ? Fiddle::VERSION : '1.0.0'
  Gem::Version.new(version) >= Gem::Version.new('1.0.1')
end

def ffi_malloc(struct)
  struct_type = LibUI::FFI.const_get(struct)
  if fiddle_support_malloc_free? then
    struct_type.malloc(Fiddle::RUBY_FREE)
  else
    ptr = struct_type.malloc
    ptr.to_ptr.free = Fiddle::RUBY_FREE
    ptr
  end
end

def gui_port_handle_content(area, area_params, i, port, status)
  base_font = ffi_malloc :FontDescriptor
  base_font.Family = 'Arial'
  base_font.Size = 16
  base_font.Weight = 500
  base_font.Italic = 0
  base_font.Stretch = 4

  create_attr_string = proc do |str, color|
    str = String(str)
    astr = LibUI.new_attributed_string(str)
    color_percent = color.map do |i| Rational(i, 255).to_f end
    acolor = LibUI.new_color_attribute(*(color_percent))
    LibUI.attributed_string_set_attribute(
      astr, acolor,
      0, str.size,
    )
    astr
  end

  str_colors = {
    none: create_attr_string.call(port, [0, 0, 0, 255]),
    bad:  create_attr_string.call(port, [224, 0, 0, 255]),
    ok:   create_attr_string.call(port, [0, 192, 0, 255]),
  }

  w_split  = area_params.AreaWidth / 8
  h_split = area_params.AreaHeight / 6

  text_params = nil
  do_create_text_param = proc do |key|
    text_params = ffi_malloc :DrawTextLayoutParams if text_params.nil?
    text_params.String = str_colors[key]
    text_params.DefaultFont = base_font
    text_params.Width = w_split
    text_params.Align = 1
  end

  do_draw_base = proc do
    text_layout = LibUI.draw_new_text_layout(text_params)
    x = w_split * (i % 7) + w_split / 2
    y = h_split * (i / 7) + h_split / 2
    LibUI.draw_text(area_params.Context, text_layout, x, y)
  ensure
    LibUI.draw_free_text_layout(text_layout)
  end

  do_init = proc do
    # $stderr.puts "#{port} init"
    do_create_text_param.call :none
    do_draw_base.call
  end

  do_success = proc do
    # $stderr.puts "#{port} succ"
    do_create_text_param.call :ok
    do_draw_base.call
  end

  do_fail = proc do
    # $stderr.puts "#{port} fail"
    do_create_text_param.call :bad
    do_draw_base.call
  end

  case status
  when :ok, :succ, :success;
              do_success
  when :fail; do_fail
  else        do_init
  end.call
end

def gui_scan
  LibUI.init
  port_status = {}
  port_jobs = {}
  LibUI.new_window('Ports Monitor', 640, 360, 0).tap do |window|
    LibUI.window_set_borderless(window, 1)

    area_handler = ffi_malloc(:AreaHandler)
    draw_context = nil
    Fiddle::Closure::BlockCaller.new(0, [1, 1, 1]) do |_, _, adp|
      area_params = LibUI::FFI::AreaDrawParams.new(adp)
      CONFIG['ports']&.each_with_index do |port, i|
        gui_port_handle_content(nil, area_params, i, port, port_status[port])
      end
    end.tap do |block|
      area_handler.Draw = block
    end
    area_handler.MouseEvent =
      area_handler.MouseCrossed =
      area_handler.DragBroken = Fiddle::Closure::BlockCaller.new(0, [0]) do end
    Fiddle::Closure::BlockCaller.new(1, [0]) do 0 end
    .tap do |block|
      area_handler.KeyEvent = block
    end
    area = LibUI.new_area(area_handler)
    CONFIG['ports']&.each_with_index do |port, i|
      port_status[port] = :none
      Thread.new(port, false) do |port, started|
        if started
          LibUI.area_queue_redraw_all(area)
        else
          Thread.stop unless started
          started = true
        end
        socket = TCPSocket.new('localhost', port)
      rescue Errno::ECONNREFUSED => e
        port_status[port] = :fail
        retry
      else
        socket.close
        port_status[port] = :ok
        sleep 0.1
        LibUI.area_queue_redraw_all(area)
      end.tap do |thread|
        port_jobs.store port, thread
      end
    end

    box = LibUI.new_horizontal_box
    LibUI.box_set_padded(box, 1)
    LibUI.box_append(box, area, 1)
    LibUI.window_set_child(window, box)
  ensure
    LibUI.control_show(window)
  end.tap do |window|
    do_finish = proc do
      # LibUI.control_destroy(window)
      LibUI.quit
      Kernel.exit 0
    end
    Thread.new do
      sleep 10
      do_finish.call
    end if false
    Thread.new do
      sleep 0.1
      port_jobs.each do |port, thread|
        thread.run if thread.alive? && thread.stop?
      end
      port_jobs.each do |port, thread|
        thread.join if thread.alive?
      end
      sleep 1
      do_finish.call
    end
  end
  LibUI.main
ensure
  LibUI.quit
end

gui_scan