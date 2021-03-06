#
# Fluentd
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#

require 'fluent/plugin/base'
require 'fluent/plugin/owned_by_mixin'
require 'fluent/unique_id'

require 'monitor'

module Fluent
  module Plugin
    class Buffer < Base
      include OwnedByMixin
      include UniqueId::Mixin
      include MonitorMixin

      class BufferError < StandardError; end
      class BufferOverflowError < BufferError; end
      class BufferChunkOverflowError < BufferError; end # A record size is larger than chunk size limit

      MINIMUM_APPEND_ATTEMPT_RECORDS = 10

      DEFAULT_CHUNK_LIMIT_SIZE =   8 * 1024 * 1024 # 8MB
      DEFAULT_TOTAL_LIMIT_SIZE = 512 * 1024 * 1024 # 512MB, same with v0.12 (BufferedOutput + buf_memory: 64 x 8MB)

      DEFAULT_CHUNK_FULL_THRESHOLD = 0.95

      configured_in :buffer

      # TODO: system total buffer limit size in bytes by SystemConfig

      config_param :chunk_limit_size, :size, default: DEFAULT_CHUNK_LIMIT_SIZE
      config_param :total_limit_size, :size, default: DEFAULT_TOTAL_LIMIT_SIZE

      # If user specify this value and (chunk_size * queue_length) is smaller than total_size,
      # then total_size is automatically configured to that value
      config_param :queue_length_limit, :integer, default: nil

      # optional new limitations
      config_param :chunk_records_limit, :integer, default: nil

      # if chunk size (or records) is 95% or more after #write, then that chunk will be enqueued
      config_param :chunk_full_threshold, :float, default: DEFAULT_CHUNK_FULL_THRESHOLD

      Metadata = Struct.new(:timekey, :tag, :variables)

      # for tests
      attr_accessor :stage_size, :queue_size
      attr_reader :stage, :queue, :dequeued, :queued_num

      def initialize
        super

        @chunk_limit_size = nil
        @total_limit_size = nil
        @queue_length_limit = nil
        @chunk_records_limit = nil

        @stage = {}    #=> Hash (metadata -> chunk) : not flushed yet
        @queue = []    #=> Array (chunks)           : already flushed (not written)
        @dequeued = {} #=> Hash (unique_id -> chunk): already written (not purged)
        @queued_num = {} # metadata => int (number of queued chunks)

        @stage_size = @queue_size = 0
        @metadata_list = [] # keys of @stage
      end

      def persistent?
        false
      end

      def configure(conf)
        super

        unless @queue_length_limit.nil?
          @total_limit_size = @chunk_limit_size * @queue_length_limit
        end
      end

      def start
        super

        @stage, @queue = resume
        @stage.each_pair do |metadata, chunk|
          @metadata_list << metadata unless @metadata_list.include?(metadata)
          @stage_size += chunk.bytesize
        end
        @queue.each do |chunk|
          @metadata_list << chunk.metadata unless @metadata_list.include?(chunk.metadata)
          @queued_num[chunk.metadata] ||= 0
          @queued_num[chunk.metadata] += 1
          @queue_size += chunk.bytesize
        end
      end

      def close
        super
        synchronize do
          @dequeued.each_pair do |chunk_id, chunk|
            chunk.close
          end
          until @queue.empty?
            @queue.shift.close
          end
          @stage.each_pair do |metadata, chunk|
            chunk.close
          end
        end
      end

      def terminate
        super
        @dequeued = @stage = @queue = @queued_num = @metadata_list = nil
        @stage_size = @queue_size = 0
      end

      def storable?
        @total_limit_size > @stage_size + @queue_size
      end

      ## TODO: for back pressure feature
      # def used?(ratio)
      #   @total_size_limit * ratio > @stage_size + @queue_size
      # end

      def resume
        # return {}, []
        raise NotImplementedError, "Implement this method in child class"
      end

      def generate_chunk(metadata)
        raise NotImplementedError, "Implement this method in child class"
      end

      def metadata_list
        synchronize do
          @metadata_list.dup
        end
      end

      def new_metadata(timekey: nil, tag: nil, variables: nil)
        Metadata.new(timekey, tag, variables)
      end

      def add_metadata(metadata)
        synchronize do
          if i = @metadata_list.index(metadata)
            @metadata_list[i]
          else
            @metadata_list << metadata
            metadata
          end
        end
      end

      def metadata(timekey: nil, tag: nil, variables: nil)
        meta = new_metadata(timekey: timekey, tag: tag, variables: variables)
        add_metadata(meta)
      end

      # metadata MUST have consistent object_id for each variation
      # data MUST be Array of serialized events, or EventStream
      # metadata_and_data MUST be a hash of { metadata => data }
      def write(metadata_and_data, format: nil, size: nil, enqueue: false)
        return if metadata_and_data.size < 1
        raise BufferOverflowError, "buffer space has too many data" unless storable?

        staged_bytesize = 0
        operated_chunks = []
        unstaged_chunks = {} # metadata => [chunk, chunk, ...]
        chunks_to_enqueue = []

        begin
          metadata_and_data.each do |metadata, data|
            write_once(metadata, data, format: format, size: size) do |chunk, adding_bytesize|
              chunk.mon_enter # add lock to prevent to be committed/rollbacked from other threads
              operated_chunks << chunk
              if chunk.staged?
                staged_bytesize += adding_bytesize
              elsif chunk.unstaged?
                unstaged_chunks[metadata] ||= []
                unstaged_chunks[metadata] << chunk
              end
            end
          end

          return if operated_chunks.empty?

          # Now, this thread acquires many locks of chunks... getting buffer-global lock causes dead lock.
          # Any operations needs buffer-global lock (including enqueueing) should be done after releasing locks.

          first_chunk = operated_chunks.shift
          # Following commits for other chunks also can finish successfully if the first commit operation
          # finishes without any exceptions.
          # In most cases, #commit just requires very small disk spaces, so major failure reason are
          # permission errors, disk failures and other permanent(fatal) errors.
          begin
            first_chunk.commit
            if enqueue || first_chunk.unstaged? || chunk_size_full?(first_chunk)
              chunks_to_enqueue << first_chunk
            end
            first_chunk.mon_exit
          rescue
            operated_chunks.unshift(first_chunk)
            raise
          end

          errors = []
          # Buffer plugin estimates there's no serious error cause: will commit for all chunks eigher way
          operated_chunks.each do |chunk|
            begin
              chunk.commit
              if enqueue || chunk.unstaged? || chunk_size_full?(chunk)
                chunks_to_enqueue << chunk
              end
              chunk.mon_exit
            rescue => e
              chunk.rollback
              chunk.mon_exit
              errors << e
            end
          end

          # All locks about chunks are released.

          synchronize do
            # At here, staged chunks may be enqueued by other threads.
            @stage_size += staged_bytesize

            chunks_to_enqueue.each do |c|
              if c.staged? && (enqueue || chunk_size_full?(c))
                m = c.metadata
                enqueue_chunk(m)
                if unstaged_chunks[m]
                  u = unstaged_chunks[m].pop
                  if u.unstaged? && !chunk_size_full?(u)
                    @stage[m] = u.staged!
                    @stage_size += u.bytesize
                  end
                end
              elsif c.unstaged?
                enqueue_unstaged_chunk(c)
              else
                # previously staged chunk is already enqueued, closed or purged.
                # no problem.
              end
            end
          end

          operated_chunks.clear if errors.empty?

          if errors.size > 0
            log.warn "error occurs in committing chunks: only first one raised", errors: errors.map(&:class)
            raise errors.first
          end
        ensure
          operated_chunks.each do |chunk|
            chunk.rollback rescue nil # nothing possible to do for #rollback failure
            if chunk.unstaged?
              chunk.purge rescue nil # to prevent leakage of unstaged chunks
            end
            chunk.mon_exit rescue nil # this may raise ThreadError for chunks already committed
          end
        end
      end

      def queued_records
        synchronize { @queue.reduce(0){|r, chunk| r + chunk.size } }
      end

      def queued?(metadata=nil)
        synchronize do
          if metadata
            n = @queued_num[metadata]
            n && n.nonzero?
          else
            !@queue.empty?
          end
        end
      end

      def enqueue_chunk(metadata)
        synchronize do
          chunk = @stage.delete(metadata)
          return nil unless chunk

          chunk.synchronize do
            if chunk.empty?
              chunk.close
            else
              @queue << chunk
              @queued_num[metadata] = @queued_num.fetch(metadata, 0) + 1
              chunk.enqueued! if chunk.respond_to?(:enqueued!)
            end
          end
          bytesize = chunk.bytesize
          @stage_size -= bytesize
          @queue_size += bytesize
        end
        nil
      end

      def enqueue_unstaged_chunk(chunk)
        synchronize do
          chunk.synchronize do
            metadata = chunk.metadata
            @queue << chunk
            @queued_num[metadata] = @queued_num.fetch(metadata, 0) + 1
            chunk.enqueued! if chunk.respond_to?(:enqueued!)
          end
          @queue_size += chunk.bytesize
        end
      end

      def enqueue_all
        synchronize do
          if block_given?
            @stage.keys.each do |metadata|
              chunk = @stage[metadata]
              v = yield metadata, chunk
              enqueue_chunk(metadata) if v
            end
          else
            @stage.keys.each do |metadata|
              enqueue_chunk(metadata)
            end
          end
        end
      end

      def dequeue_chunk
        return nil if @queue.empty?
        synchronize do
          chunk = @queue.shift

          # this buffer is dequeued by other thread just before "synchronize" in this thread
          return nil unless chunk

          @dequeued[chunk.unique_id] = chunk
          @queued_num[chunk.metadata] -= 1 # BUG if nil, 0 or subzero
          chunk
        end
      end

      def takeback_chunk(chunk_id)
        synchronize do
          chunk = @dequeued.delete(chunk_id)
          return false unless chunk # already purged by other thread
          @queue.unshift(chunk)
          @queued_num[chunk.metadata] += 1 # BUG if nil
        end
        true
      end

      def purge_chunk(chunk_id)
        synchronize do
          chunk = @dequeued.delete(chunk_id)
          return nil unless chunk # purged by other threads

          metadata = chunk.metadata
          begin
            bytesize = chunk.bytesize
            chunk.purge
            @queue_size -= bytesize
          rescue => e
            log.error "failed to purge buffer chunk", chunk_id: dump_unique_id_hex(chunk_id), error_class: e.class, error: e
          end

          if metadata && !@stage[metadata] && (!@queued_num[metadata] || @queued_num[metadata] < 1)
            @metadata_list.delete(metadata)
          end
        end
        nil
      end

      def clear_queue!
        synchronize do
          until @queue.empty?
            begin
              q = @queue.shift
              log.debug("purging a chunk in queue"){ {id: dump_unique_id_hex(chunk.unique_id), bytesize: chunk.bytesize, size: chunk.size} }
              q.purge
            rescue => e
              log.error "unexpected error while clearing buffer queue", error_class: e.class, error: e
            end
          end
          @queue_size = 0
        end
      end

      def chunk_size_over?(chunk)
        chunk.bytesize > @chunk_limit_size || (@chunk_records_limit && chunk.size > @chunk_records_limit)
      end

      def chunk_size_full?(chunk)
        chunk.bytesize >= @chunk_limit_size * @chunk_full_threshold || (@chunk_records_limit && chunk.size >= @chunk_records_limit * @chunk_full_threshold)
      end

      class ShouldRetry < StandardError; end

      # write once into a chunk
      # 1. append whole data into existing chunk
      # 2. commit it & return unless chunk_size_over?
      # 3. enqueue existing chunk & retry whole method if chunk was not empty
      # 4. go to step_by_step writing

      def write_once(metadata, data, format: nil, size: nil, &block)
        return if data.empty?

        stored = false
        adding_bytesize = nil

        chunk = synchronize { @stage[metadata] ||= generate_chunk(metadata).staged! }
        enqueue_chunk_before_retry = false
        chunk.synchronize do
          # retry this method if chunk is already queued (between getting chunk and entering critical section)
          raise ShouldRetry unless chunk.staged?

          empty_chunk = chunk.empty?

          original_bytesize = chunk.bytesize
          begin
            if format
              serialized = format.call(data)
              chunk.concat(serialized, size ? size.call : data.size)
            else
              chunk.append(data)
            end
            adding_bytesize = chunk.bytesize - original_bytesize

            if chunk_size_over?(chunk)
              if format && empty_chunk
                log.warn "chunk bytes limit exceeds for an emitted event stream: #{adding_bytesize}bytes"
              end
              chunk.rollback

              if format && !empty_chunk
                # Event streams should be appended into a chunk at once
                # as far as possible, to improve performance of formatting.
                # Event stream may be a MessagePackEventStream. We don't want to split it into
                # 2 or more chunks (except for a case that the event stream is larger than chunk limit).
                enqueue_chunk_before_retry = true
                raise ShouldRetry
              end
            else
              stored = true
            end
          rescue
            chunk.rollback
            raise
          end

          if stored
            block.call(chunk, adding_bytesize)
          end
        end

        unless stored
          # try step-by-step appending if data can't be stored into existing a chunk in non-bulk mode
          #
          # 1/10 size of original event stream (splits_count == 10) seems enough small
          # to try emitting events into existing chunk.
          # it does not matter to split event stream into very small splits, because chunks have less
          # overhead to write data many times (even about file buffer chunks).
          write_step_by_step(metadata, data, format, 10, &block)
        end
      rescue ShouldRetry
        enqueue_chunk(metadata) if enqueue_chunk_before_retry
        retry
      end

      # EventStream can be split into many streams
      # because (es1 + es2).to_msgpack_stream == es1.to_msgpack_stream + es2.to_msgpack_stream

      # 1. split event streams into many (10 -> 100 -> 1000 -> ...) chunks
      # 2. append splits into the staged chunks as much as possible
      # 3. create unstaged chunk and append rest splits -> repeat it for all splits

      def write_step_by_step(metadata, data, format, splits_count, &block)
        splits = []
        if splits_count > data.size
          splits_count = data.size
        end
        slice_size = if data.size % splits_count == 0
                       data.size / splits_count
                     else
                       data.size / (splits_count - 1)
                     end
        slice_origin = 0
        while slice_origin < data.size
          splits << data.slice(slice_origin, slice_size)
          slice_origin += slice_size
        end

        # This method will append events into the staged chunk at first.
        # Then, will generate chunks not staged (not queued) to append rest data.
        staged_chunk_used = false
        modified_chunks = []
        get_next_chunk = ->(){
          c = if staged_chunk_used
                # Staging new chunk here is bad idea:
                # Recovering whole state including newly staged chunks is much harder than current implementation.
                generate_chunk(metadata)
              else
                synchronize{ @stage[metadata] ||= generate_chunk(metadata).staged! }
              end
          modified_chunks << c
          c
        }

        writing_splits_index = 0
        enqueue_chunk_before_retry = false

        while writing_splits_index < splits.size
          chunk = get_next_chunk.call
          chunk.synchronize do
            raise ShouldRetry unless chunk.writable?
            staged_chunk_used = true if chunk.staged?

            original_bytesize = chunk.bytesize
            begin
              while writing_splits_index < splits.size
                split = splits[writing_splits_index]
                if format
                  chunk.concat(format.call(split), split.size)
                else
                  chunk.append(split)
                end

                if chunk_size_over?(chunk) # split size is larger than difference between size_full? and size_over?
                  chunk.rollback

                  if split.size == 1 && original_bytesize == 0
                    big_record_size = format ? format.call(split).bytesize : split.first.bytesize
                    raise BufferChunkOverflowError, "a #{big_record_size}bytes record is larger than buffer chunk limit size"
                  end

                  if chunk_size_full?(chunk) || split.size == 1
                    enqueue_chunk_before_retry = true
                  else
                    splits_count *= 10
                  end

                  raise ShouldRetry
                end

                writing_splits_index += 1

                if chunk_size_full?(chunk)
                  break
                end
              end
            rescue
              chunk.purge if chunk.unstaged? # unstaged chunk will leak unless purge it
              raise
            end

            block.call(chunk, chunk.bytesize - original_bytesize)
          end
        end
      rescue ShouldRetry
        modified_chunks.each do |mc|
          mc.rollback rescue nil
          if mc.unstaged?
            mc.purge rescue nil
          end
        end
        enqueue_chunk(metadata) if enqueue_chunk_before_retry
        retry
      end
    end
  end
end
