require 'spec_helper'

module Calagator
  describe Event, type: :model do
    describe 'in general'  do
      it 'should be valid' do
        event = Event.new(title: 'Event title', start_time: Time.zone.parse('2008.04.12'))
        expect(event).to be_valid
      end

      it 'should add a http:// prefix to urls without one' do
        event = Event.new(title: 'Event title', start_time: Time.zone.parse('2008.04.12'), url: 'google.com')
        expect(event).to be_valid
      end

      it 'validates blacklisted words' do
        BlacklistValidator.any_instance.stub(patterns: [/\bcialis\b/, /\bviagra\b/])
        event = Event.new(title: 'Foo bar cialis', start_time: Time.zone.parse('2008.04.12'), url: 'google.com')
        expect(event).not_to be_valid
      end

      it 'can be locked' do
        event = Event.create(title: 'Event title', start_time: Time.zone.parse('2008.04.12'))
        event.lock_editing!
        expect(event.locked).to eq(true)
      end

      it 'can be unlocked' do
        event = Event.create(title: 'Event title', start_time: Time.zone.parse('2008.04.12'), locked: true)
        event.unlock_editing!
        expect(event.locked).to eq(false)
      end

      it "can't be deleted if it's locked" do
        event = Event.create(title: 'Event title', start_time: Time.zone.parse('2008.04.12'))
        event.lock_editing!
        expect(event.destroy).to eq(false)
      end
    end

    describe 'when checking time status' do
      it 'should be old if event ended before today' do
        expect(FactoryBot.build(:event, start_time: 2.days.ago, end_time: 1.day.ago)).to be_old
      end

      it 'should be current if event is happening today' do
        expect(FactoryBot.build(:event, start_time: 1.hour.from_now)).to be_current
      end

      it 'should be ongoing if it began before today but ends today or later' do
        expect(FactoryBot.build(:event, start_time: 1.day.ago, end_time: 1.day.from_now)).to be_ongoing
      end
    end

    describe 'dealing with tags' do
      before do
        @tags = 'some, tags'
        @event = Event.new(title: 'Tagging Day', start_time: now)
      end

      it 'should be taggable' do
        expect(@event.tag_list).to eq []
      end

      it 'should just cache tagging if it is a new record' do
        expect(@event).not_to receive :save
        expect(@event).to be_new_record
        @event.tag_list = @tags
        expect(@event.tag_list.to_s).to eq @tags
      end

      it 'should use tags with punctuation' do
        tags = ['.net', 'foo-bar']
        @event.tag_list = tags.join(', ')
        @event.save

        @event.reload
        expect(@event.tags.map(&:name).sort).to eq tags.sort
      end

      it 'should not interpret numeric tags as IDs' do
        tag = '123'
        @event.tag_list = tag
        @event.save

        @event.reload
        expect(@event.tags.first.name).to eq '123'
      end

      it 'should return a collection of events for a given tag' do
        @event.tag_list = @tags
        @event.save
        expect(Event.tagged_with('tags')).to eq [@event]
      end
    end

    describe 'when parsing' do
      before do
        @basic_hcal = read_sample('hcal_basic.xml')
        @basic_venue = mock_model(Venue, title: 'Argent Hotel, San Francisco, CA', full_address: '50 3rd St, San Francisco, CA 94103')
        @basic_event = Event.new(
          title: 'Web 2.0 Conference',
          url: 'http://www.web2con.com/',
          start_time: 1.day.from_now,
          end_time: nil,
          venue: @basic_venue
        )
      end

      it 'should parse an iCalendar into an Event' do
        url = 'http://foo.bar/'
        actual_ical = Event::IcalRenderer.render(@basic_event)
        stub_request(:get, url).to_return(body: actual_ical)

        events = Source::Parser.to_events(url: url)

        expect(events.size).to eq 1
        event = events.first
        expect(event.title).to eq @basic_event.title
        expect(event.url).to eq @basic_event.url
        expect(event.description).to be_blank

        expect(event.venue.title).to match "#{@basic_event.venue.title}: #{@basic_event.venue.full_address}"
      end

      it 'should parse an iCalendar into an Event without a URL and generate it' do
        generated_url = 'http://foo.bar/'
        @basic_event.url = nil
        actual_ical = Event::IcalRenderer.render(@basic_event, url_helper: ->(_event) { generated_url })
        url = 'http://foo.bar/'
        stub_request(:get, url).to_return(body: actual_ical)

        events = Source::Parser.to_events(url: url)

        expect(events.size).to eq 1
        event = events.first
        expect(event.title).to eq @basic_event.title
        expect(event.url).to eq @basic_event.url
        expect(event.description).to match /Imported from: #{generated_url}/

        expect(event.venue.title).to match "#{@basic_event.venue.title}: #{@basic_event.venue.full_address}"
      end
    end

    describe 'when processing date' do
      before do
        @event = Event.new(title: 'MyEvent')
      end

      it 'should fail to validate if start time is nil' do
        @event.start_time = nil
        expect(@event).not_to be_valid
        expect(@event.errors[:start_time].size).to eq(1)
      end

      it 'should fail to validate if start time is blank' do
        @event.start_time = ''
        expect(@event).not_to be_valid
        expect(@event.errors[:start_time].size).to eq(1)
      end

      it 'should fail to validate if end_time is earlier than start time ' do
        @event.start_time = now
        @event.end_time = @event.start_time - 2.hours
        expect(@event).to be_invalid
        expect(@event.errors[:end_time].size).to eq(1)
      end
    end

    describe 'when processing url' do
      before do
        @event = Event.new(title: 'MyEvent', start_time: now)
      end

      let(:valid_urls) do
        [
          'hackoregon.org',
          'http://www.meetup.com/Hack_Oregon-Data/events/',
          'example.com',
          'sub.example.com/',
          'sub.domain.my-example.com',
          'example.com/?stuff=true',
          'example.com:5000/?stuff=true',
          'sub.domain.my-example.com/path/to/file/hello.html',
          'hello.museum',
          'http://example.com'
        ]
      end

      let(:invalid_urls) do
        [
          'hackoregon.org, http://www.meetup.com/Hack_Oregon-Data/events/',
          "hackoregon.org\nhttp://www.meetup.com/",
          'htttp://www.example.com'
        ]
      end

      it 'should validate with valid urls (with scheme included or not)' do
        valid_urls.each do |valid_url|
          @event.url = valid_url
          expect(@event).to be_valid
        end
      end

      it 'should fail to validate with invalid urls (with scheme included or not)' do
        invalid_urls.each do |invalid_url|
          @event.url = invalid_url
          expect(@event).to be_invalid
        end
      end
    end

    describe '#start_time=' do
      it 'should clear with nil' do
        expect(Event.new(start_time: nil).start_time).to be_nil
      end

      it 'should set from date String' do
        event = Event.new(start_time: '2009-01-02')
        expect(event.start_time).to eq Time.zone.parse('2009-01-02')
      end

      it 'should set from date-time String' do
        event = Event.new(start_time: '2009-01-02 03:45')
        expect(event.start_time).to eq Time.zone.parse('2009-01-02 03:45')
      end

      it 'should set from Date' do
        event = Event.new(start_time: Date.parse('2009-02-01'))
        expect(event.start_time).to eq Time.zone.parse('2009-02-01')
      end

      it 'should set from DateTime' do
        event = Event.new(start_time: Time.zone.parse('2009-01-01 05:30'))
        expect(event.start_time).to eq Time.zone.parse('2009-01-01 05:30')
      end

      it 'should flag an invalid time and reset to nil' do
        event = Event.new(start_time: '2010/1/1')
        event.start_time = '1/0'
        expect(event.start_time).to be_nil
        expect(event.errors[:start_time]).to be_present
      end
    end

    describe '#end_time=' do
      it 'should clear with nil' do
        expect(Event.new(end_time: nil).end_time).to be_nil
      end

      it 'should set from date String' do
        event = Event.new(end_time: '2009-01-02')
        expect(event.end_time).to eq Time.zone.parse('2009-01-02')
      end

      it 'should set from date-time String' do
        event = Event.new(end_time: '2009-01-02 03:45')
        expect(event.end_time).to eq Time.zone.parse('2009-01-02 03:45')
      end

      it 'should set from Date' do
        event = Event.new(end_time: Date.parse('2009-02-01'))
        expect(event.end_time).to eq Time.zone.parse('2009-02-01')
      end

      it 'should set from DateTime' do
        event = Event.new(end_time: Time.zone.parse('2009-01-01 05:30'))
        expect(event.end_time).to eq Time.zone.parse('2009-01-01 05:30')
      end

      it 'should flag an invalid time' do
        event = Event.new(end_time: '1/0')
        expect(event.errors[:end_time]).to be_present
      end
    end

    describe '#duration' do
      it 'returns the event length in seconds' do
        event = Event.new(start_time: '2010-01-01', end_time: '2010-01-03')
        expect(event.duration).to eq(172_800)
      end

      it "returns zero if start and end times aren't present" do
        expect(Event.new.duration).to eq(0)
      end
    end

    describe '.search_tag' do
      before do
        @c = FactoryBot.create(:event, title: 'c', tag_list: %w[tag wtf], start_time: 3.minutes.ago)
        @b = FactoryBot.create(:event, title: 'b', tag_list: %w[omg wtf], start_time: 2.minutes.ago)
        @a = FactoryBot.create(:event, title: 'a', tag_list: %w[tag omg], start_time: 1.minute.ago)
      end

      it 'finds events with the given tag' do
        Event.search_tag('tag').should == [@c, @a]
      end

      it 'accepts an order option' do
        Event.search_tag('tag', order: 'name').should == [@a, @c]
      end
    end

    describe 'when finding by dates' do
      before do
        @today_midnight = today
        @yesterday = @today_midnight.yesterday
        @tomorrow = @today_midnight.tomorrow

        @this_venue = Venue.create!(title: 'This venue')

        @started_before_today_and_ends_after_today = Event.create!(
          title: 'Event in progress',
          start_time: @yesterday,
          end_time: @tomorrow,
          venue_id: @this_venue.id
        )

        @started_midnight_and_continuing_after = Event.create!(
          title: 'Midnight start',
          start_time: @today_midnight,
          end_time: @tomorrow,
          venue_id: @this_venue.id
        )

        @started_and_ended_yesterday = Event.create!(
          title: 'Yesterday start',
          start_time: @yesterday,
          end_time: @yesterday.end_of_day,
          venue_id: @this_venue.id
        )

        @started_today_and_no_end_time = Event.create!(
          title: 'nil end time',
          start_time: @today_midnight,
          end_time: nil,
          venue_id: @this_venue.id
        )

        @starts_and_ends_tomorrow = Event.create!(
          title: 'starts and ends tomorrow',
          start_time: @tomorrow,
          end_time: @tomorrow.end_of_day,
          venue_id: @this_venue.id
        )

        @starts_after_tomorrow = Event.create!(
          title: 'Starting after tomorrow',
          start_time: @tomorrow + 1.day,
          venue_id: @this_venue.id
        )

        @started_before_today_and_ends_at_midnight = Event.create!(
          title: 'Midnight end',
          start_time: @yesterday,
          end_time: @today_midnight,
          venue_id: @this_venue.id
        )

        @future_events_for_this_venue = @this_venue.events.future
      end

      describe 'for future events' do
        before do
          @future_events = Event.future
        end

        it 'should include events that started earlier today' do
          expect(@future_events).to include @started_midnight_and_continuing_after
        end

        it 'should include events with no end time that started today' do
          expect(@future_events).to include @started_today_and_no_end_time
        end

        it 'should include events that started before today and ended after today' do
          events = Event.future
          expect(events).to include @started_before_today_and_ends_after_today
        end

        it 'should include events with no end time that started today' do
          expect(@future_events).to include @started_today_and_no_end_time
        end

        it 'should not include events that ended before today' do
          expect(@future_events).not_to include @started_and_ended_yesterday
        end
      end

      describe 'for future events with venue' do
        before do
          @another_venue = Venue.create!(title: 'Another venue')

          @future_event_another_venue = Event.create!(
            title: 'Starting after tomorrow',
            start_time: @tomorrow + 1.day,
            venue_id: @another_venue.id
          )

          @future_event_no_venue = Event.create!(
            title: 'Starting after tomorrow',
            start_time: @tomorrow + 1.day
          )
        end

        # TODO: Consider moving these examples elsewhere because they don't appear to relate to this scope. This comment applies to the examples from here...
        it 'should include events that started earlier today' do
          expect(@future_events_for_this_venue).to include @started_midnight_and_continuing_after
        end

        it 'should include events with no end time that started today' do
          expect(@future_events_for_this_venue).to include @started_today_and_no_end_time
        end

        it 'should include events that started before today and ended after today' do
          expect(@future_events_for_this_venue).to include @started_before_today_and_ends_after_today
        end

        it 'should not include events that ended before today' do
          expect(@future_events_for_this_venue).not_to include @started_and_ended_yesterday
        end
        # TODO: ...to here.

        it 'should not include events for another venue' do
          expect(@future_events_for_this_venue).not_to include @future_event_another_venue
        end

        it 'should not include events with no venue' do
          expect(@future_events_for_this_venue).not_to include @future_event_no_venue
        end
      end

      describe 'for date range' do
        it 'should include events that started earlier today' do
          events = Event.within_dates(@today_midnight, @tomorrow)
          expect(events).to include @started_midnight_and_continuing_after
        end

        it 'should include events that started before today and end after today' do
          events = Event.within_dates(@today_midnight, @tomorrow)
          expect(events).to include @started_before_today_and_ends_after_today
        end

        it 'should not include past events' do
          events = Event.within_dates(@today_midnight, @tomorrow)
          expect(events).not_to include @started_and_ended_yesterday
        end

        it 'should exclude events that start after the end of the range' do
          events = Event.within_dates(@tomorrow, @tomorrow)
          expect(events).not_to include @started_today_and_no_end_time
        end
      end
    end

    describe 'when ordering' do
      describe 'with .ordered_by_ui_field' do
        it 'defaults to order by start time' do
          event1 = FactoryBot.create(:event, start_time: Time.zone.parse('2003-01-01'))
          event2 = FactoryBot.create(:event, start_time: Time.zone.parse('2002-01-01'))
          event3 = FactoryBot.create(:event, start_time: Time.zone.parse('2001-01-01'))

          events = Event.ordered_by_ui_field(nil)
          expect(events).to eq([event3, event2, event1])
        end

        it 'can order by event name' do
          event1 = FactoryBot.create(:event, title: 'CU there')
          event2 = FactoryBot.create(:event, title: 'Be there')
          event3 = FactoryBot.create(:event, title: 'An event')

          events = Event.ordered_by_ui_field('name')
          expect(events).to eq([event3, event2, event1])
        end

        it 'can order by venue name' do
          event1 = FactoryBot.create(:event, venue: FactoryBot.create(:venue, title: 'C venue'))
          event2 = FactoryBot.create(:event, venue: FactoryBot.create(:venue, title: 'B venue'))
          event3 = FactoryBot.create(:event, venue: FactoryBot.create(:venue, title: 'A venue'))

          events = Event.ordered_by_ui_field('venue')
          expect(events).to eq([event3, event2, event1])
        end
      end
    end

    describe 'with finding duplicates' do
      before do
        @non_duplicate_event = FactoryBot.create(:event)
        @duplicate_event = FactoryBot.create(:duplicate_event)
        @events = [@non_duplicate_event, @duplicate_event]
      end

      it 'should find all events that have not been marked as duplicate' do
        non_duplicates = Event.non_duplicates
        expect(non_duplicates).to include @non_duplicate_event
        expect(non_duplicates).not_to include @duplicate_event
      end

      it 'should find all events that have been marked as duplicate' do
        duplicates = Event.marked_duplicates
        expect(duplicates).to include @duplicate_event
        expect(duplicates).not_to include @non_duplicate_event
      end
    end

    describe 'with finding duplicates (integration test)' do
      before do
        # this event should always be omitted from the results
        past = FactoryBot.create(:event, start_time: 1.week.ago)
      end

      subject do
        FactoryBot.create(:event)
      end

      it 'should return future events when provided na' do
        future = Event.create!(title: subject.title, start_time: 1.day.from_now)
        events = Event.find_duplicates_by_type('na')
        expect(events).to eq([nil] => [subject, future])
      end

      it 'should find duplicate title by title' do
        clone = Event.create!(title: subject.title, start_time: subject.start_time)
        events = Event.find_duplicates_by_type('title')
        expect(events).to eq([subject.title] => [subject, clone])
      end

      it 'should find duplicate title by any' do
        clone = Event.create!(title: subject.title, start_time: subject.start_time + 1.minute)
        events = Event.find_duplicates_by_type('title')
        expect(events).to eq([subject.title] => [subject, clone])
      end

      it 'should not find duplicate title by url' do
        clone = Event.create!(title: subject.title, start_time: subject.start_time)
        events = Event.find_duplicates_by_type('url')
        expect(events).to be_empty
      end

      it 'should find complete duplicates by all' do
        clone = Event.create!(subject.attributes.merge(id: nil))
        events = Event.find_duplicates_by_type('all')
        expect(events).to eq([nil] => [subject, clone])
      end

      it 'should not find incomplete duplicates by all' do
        clone = Event.create!(subject.attributes.merge(title: 'SpaceCube', start_time: subject.start_time, id: nil))
        events = Event.find_duplicates_by_type('all')
        expect(events).to be_empty
      end

      it 'should find duplicate for matching multiple fields' do
        clone = Event.create!(title: subject.title, start_time: subject.start_time)
        events = Event.find_duplicates_by_type('title,start_time')
        expect(events).to eq([subject.title, subject.start_time] => [subject, clone])
      end

      it 'should not find duplicates for mismatching multiple fields' do
        clone = Event.create!(title: 'SpaceCube', start_time: subject.start_time)
        events = Event.find_duplicates_by_type('title,start_time')
        expect(events).to be_empty
      end
    end

    describe 'when squashing duplicates (integration test)' do
      before do
        @event = FactoryBot.create(:event, :with_venue)
        @venue = @event.venue
      end

      it "should consolidate associations, merge tags, and update the venue's counter_cache" do
        @event.tag_list = %w[first second] # master event contains one duplicate tag, and one unique tag

        clone = Event.create!(@event.attributes.merge(id: nil))
        clone.tag_list.replace %w[second third] # duplicate event also contains one duplicate tag, and one unique tag
        clone.save!
        clone.reload
        expect(clone).not_to be_duplicate
        expect(@venue.reload.events_count).to eq 2

        Event.squash(@event, clone)
        expect(@event.tag_list.to_a.sort).to eq %w[first second third] # master now contains all three tags
        expect(clone.duplicate_of).to eq @event
        expect(@venue.reload.events_count).to eq 1
      end
    end

    describe 'when checking for squashing' do
      before do
        @today  = today
        @master = Event.create!(title: 'Master',    start_time: @today)
        @slave1 = Event.create!(title: '1st slave', start_time: @today, duplicate_of_id: @master.id)
        @slave2 = Event.create!(title: '2nd slave', start_time: @today, duplicate_of_id: @slave1.id)
        @orphan = Event.create!(title: 'orphan',    start_time: @today, duplicate_of_id: 999_999)
      end

      it 'should recognize a master' do
        expect(@master).to be_a_master
      end

      it 'should recognize a slave' do
        expect(@slave1).to be_a_slave
      end

      it 'should not think that a slave is a master' do
        expect(@slave2).not_to be_a_master
      end

      it 'should not think that a master is a slave' do
        expect(@master).not_to be_a_slave
      end

      it 'should return the progenitor of a child' do
        expect(@slave1.progenitor).to eq @master
      end

      it 'should return the progenitor of a grandchild' do
        expect(@slave2.progenitor).to eq @master
      end

      it 'should return a master as its own progenitor' do
        expect(@master.progenitor).to eq @master
      end

      it 'should return a marked duplicate as progenitor if it is orphaned' do
        expect(@orphan.progenitor).to eq @orphan
      end
    end

    describe 'when versioning' do
      it 'should have versions' do
        expect(Event.new.versions).to eq []
      end

      it 'should create a new version after updating' do
        event = Event.create!(title: 'Event title', start_time: Time.zone.parse('2008.04.12'))
        expect(event.versions.count).to eq 1

        event.title = 'New Title'
        event.save!
        expect(event.versions.count).to eq 2
      end
    end

    describe 'when converting to iCal' do
      def ical_roundtrip(events, opts = {})
        parsed_events = RiCal.parse_string(Event::IcalRenderer.render(events, opts)).first.events
        if events.is_a?(Event)
          parsed_events.first
        else
          parsed_events
        end
      end

      it 'should produce parsable iCal output' do
        expect { ical_roundtrip(FactoryBot.build(:event)) }.not_to raise_error
      end

      it 'should represent an event without an end time as a 1-hour block' do
        event = FactoryBot.build(:event, start_time: now, end_time: nil)
        expect(event.end_time).to be_blank

        rt = ical_roundtrip(event)
        expect(rt.dtend - rt.dtstart).to eq 1.hour
      end

      it 'should set the appropriate end time if one is given' do
        event = FactoryBot.build(:event, start_time: now, end_time: now + 2.hours)

        rt = ical_roundtrip(event)
        expect(rt.dtend - rt.dtstart).to eq 2.hours
      end

      describe "when comparing Event's attributes to its iCalendar output" do
        let(:event) { FactoryBot.build(:event, id: 123, created_at: now) }
        let(:ical) { ical_roundtrip(event) }

        { summary: :title,
          created: :created_at,
          last_modified: :updated_at,
          description: :description,
          url: :url,
          dtstart: :start_time,
          dtstamp: :created_at }.each do |ical_attribute, model_attribute|
          it "should map the Event's #{model_attribute} attribute to '#{ical_attribute}' in the iCalendar output" do
            model_value = event.send(model_attribute)
            ical_value = ical.send(ical_attribute)

            case model_value
            when ActiveSupport::TimeWithZone
              # Compare raw time because one is using local time zone, while other is using UTC time.
              expect(model_value.to_i).to eq ical_value.to_i
            else
              expect(model_value).to eq ical_value
            end
          end
        end
      end

      it 'should call the URL helper to generate a UID' do
        event = FactoryBot.build(:event)
        expect(ical_roundtrip(event, url_helper: ->(_e) { "UID'D!" }).uid).to eq "UID'D!"
      end

      it 'should strip HTML from the description' do
        event = FactoryBot.create(:event, description: '<blink>OMFG HTML IS TEH AWESOME</blink>')
        expect(ical_roundtrip(event).description).not_to include '<blink>'
      end

      it 'should include tags in the description' do
        event = FactoryBot.build(:event)
        event.tag_list = 'tags, folksonomy, categorization'
        expect(ical_roundtrip(event).description).to include event.tag_list.to_s
      end

      it 'should leave URL blank if no URL is provided' do
        event = FactoryBot.build(:event, url: nil)
        expect(ical_roundtrip(event).url).to be_nil
      end

      it 'should have Source URL if URL helper is given)' do
        event = FactoryBot.build(:event)
        expect(ical_roundtrip(event, url_helper: ->(_e) { 'FAKE' }).description).to match /FAKE/
      end

      it 'should create multi-day entries for multi-day events' do
        time = Time.zone.now
        event = FactoryBot.build(:event, start_time: time, end_time: time + 4.days)
        parsed_event = ical_roundtrip(event)

        start_time = Date.current
        expect(parsed_event.dtstart).to eq start_time
        expect(parsed_event.dtend).to eq(start_time + 5.days)
      end

      describe 'sequence' do
        def event_to_ical(event)
          RiCal.parse_string(Event::IcalRenderer.render([event])).first.events.first
        end

        it 'should set an initial sequence on a new event' do
          event = FactoryBot.create(:event)
          ical = event_to_ical(event)
          expect(ical.sequence).to eq 1
        end

        it 'should increment the sequence if it is updated' do
          event = FactoryBot.create(:event)
          event.update_attribute(:title, 'Update 1')
          ical = event_to_ical(event)
          expect(ical.sequence).to eq 2
        end

        # it "should offset the squence based the global Calagator.icalendar_sequence_offset" do
        # Calagator.should_receive(:icalendar_sequence_offset).and_return(41)
        # event = FactoryBot.build(:event)
        # ical = event_to_ical(event)
        # ical.sequence.should eq 42
        # end
      end

      describe '- the headers' do
        before do
          @data = Event::IcalRenderer.render(FactoryBot.build(:event))
        end

        it 'should include the calendar name' do
          expect(@data).to match /\sX-WR-CALNAME:#{Calagator.title}\s/
        end

        it 'should include the method' do
          expect(@data).to match /\sMETHOD:PUBLISH\s/
        end

        it 'should include the scale' do
          expect(@data).to match /\sCALSCALE:Gregorian\s/i
        end
      end
    end
  end
end
