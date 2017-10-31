module Loaders::NewHTML
  def strip_html(input)
    text = CGI.unescapeHTML(input)
    if text.start_with?('<')
      text = Nokogiri::XML(text).children[0].text
    end
    text
  end

  def extract_html(input)
    text = CGI.unescapeHTML(input)
    Nokogiri::XML(text).children[0]
  end

  def extract_title
    xml = Nokogiri::HTML(text)
    unless xml.errors.empty?
      puts "Nokogiri errors for episode #{show_id}"
    end

    title = xml.at_css('head title').content
    puts title.inspect

    escaped = CGI.unescapeHTML(title)
    match = escaped.match(/"(.*)"/)
    match ||= escaped.match(/ - ([\w \-]*)/)
    match&.captures.first
  end

  def process_text!
    ActiveRecord::Base.transaction do
      set_show! unless show.present?
      delete_notes!

      xml = Nokogiri::HTML(text)
      start = xml.css('#my-tab-content')

      if start.count == 0
        raise 'No tab content found'
      elsif start.count > 1
        raise 'Too many tab contents found'
      end

      shownotes = start.css('[id^="idShownotes"], #shownotes').css('.divOutlineBody > .divOutlineList > .divOutlineItem')
      # clipsAdStuff typo on 526
      clips     = start.css('[id^="idClipsAndStuff"], #clipsAndStuff, #clipsAdStuff').css('.divOutlineBody > .divOutlineList > .divOutlineItem')

      if shownotes.empty? || clips.empty?
        empty = []
        empty << 'shownotes' if shownotes.empty?
        empty << 'clips' if clips.empty?
        message = empty.join(', ') + ' empty!'
        if show_id == 534 || show_id == 533 # Interview show, clip show
          puts message
        else
          raise message
        end
      end

      process_topics(shownotes, false)
      process_topics(clips,     true)
    end
  end

  def process_topics(nodes, are_clips)
    nodes.each do |topic_node|
      next if topic_node.text.start_with?('<')

      topic = topic_node.css('> a').map(&:text).reject(&:blank?).first
      next if topic.blank?

      notes = topic_node.next_element.css('> .divOutlineList > .divOutlineItem')

      if !are_clips && notes.all? { |note| note['class'] == 'divOutlineItem' }
        # We aren't going to get a separate title and then further
        # children nodes with the actual text
        # This is the text - and we didn't get a title node.
        notes = [topic_node]
      end

      notes.each do |note_node|
        next if note_node.text.match? /^[ ]*-+$/ # Some are just '------------' (and some start with a space)

        note = show.notes.new(
          topic: topic,
          title: note_node.text
        )

        next_node = note_node.next_element
        children = next_node.nil? || next_node['class'] == 'divOutlineItem' ?
          note_node.css('.spanOutlineText') :
          next_node.css('.divOutlineItem .spanOutlineText')

        urls = []
        entries = children.map do |entry_node|
          text = ['a', 'img', 'audio'].include?(entry_node.name) ? entry_node.to_s : entry_node.text
          next if text.blank?
          next if [
            '").addClass(n).attr(',
            '\n {{ more.more_rank',
            '-1)r&&r.push(o);else'
          ].any? { |str| text.starts_with? str }

          if entry_node.children.count == 1 && (a = entry_node.css('> a').first)
            url = a['href']
            if text.blank?
              text = File.basename(URI.parse(url).path)
            end
            urls << {text: text, url: url}
            text = "<a href='#{url}'>#{text}</a>"
          end

          next if text.blank?

          text
        end.compact

        if entries.any? || urls.any?
          note.text = entries.join("\n")

          if note.title.blank? && urls.length == 1
            url = urls.first[:url]
            extension = File.extname(url)
            note.title = "File: #{extension[1..-1]}" unless extension.blank?
          end

          note.save!
          note.url_entries.create!(urls)
        end
      end
    end
  end
end