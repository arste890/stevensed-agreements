# frozen_string_literal: true

# StevensED: safety checks shared by the DocuSeal cloud import scripts.
#
# DRY_RUN=1 rolls back the database, but files written to Active Storage are not part of the transaction.
# Two protections follow:
#   1. Dry runs (rehearsals) run only against rehearsal storage and a rehearsal database. Rehearsal storage is a
#      Disk service whose root holds the marker file STEVENSED_REHEARSAL_STORAGE; the live service never has it.
#   2. Every file uploaded during a run that does not commit (dry run, error) is deleted again from storage.
#
# IMPORT_TARGET must be set: "rehearsal" or "live". IMPORT_ROOT points at the export (default: the live export).
module ImportGuard
  MARKER = 'STEVENSED_REHEARSAL_STORAGE'
  LIVE_DATABASE = 'docuseal'
  LIVE_IMPORT_ROOT = '/data/imported/docuseal-cloud'

  module_function

  def import_root
    Pathname.new(ENV.fetch('IMPORT_ROOT', LIVE_IMPORT_ROOT))
  end

  def check!(dry_run:)
    target = ENV.fetch('IMPORT_TARGET', nil)

    check_target!(target, dry_run)
    target == 'rehearsal' ? check_rehearsal! : check_live!

    puts "Import target: #{target}; storage: #{storage_label}; database: #{database_name}; export: #{import_root}"
  end

  def check_target!(target, dry_run)
    unless %w[rehearsal live].include?(target)
      abort('Set IMPORT_TARGET=rehearsal (separate storage and database) or IMPORT_TARGET=live.')
    end

    return unless dry_run && target != 'rehearsal'

    abort('DRY_RUN=1 writes files to storage that the database rollback does not remove. ' \
          'Run dry runs only in the rehearsal environment with IMPORT_TARGET=rehearsal.')
  end

  def check_rehearsal!
    unless rehearsal_storage?
      abort("Rehearsal storage must be a Disk service whose root contains #{MARKER} (#{storage_label}).")
    end

    abort('The rehearsal must not use the live database.') if database_name == LIVE_DATABASE
  end

  def check_live!
    abort('IMPORT_TARGET=live but the configured storage is rehearsal storage.') if rehearsal_storage?
  end

  # Yields; deletes every file uploaded inside the block unless the block returns with committed: true.
  def with_upload_cleanup(dry_run:)
    keys = []
    subscriber = ActiveSupport::Notifications.subscribe('service_upload.active_storage') do |*, payload|
      keys << payload[:key]
    end
    committed = false

    result = yield
    committed = !dry_run

    result
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)

    unless committed
      keys.uniq.each { |key| ActiveStorage::Blob.service.delete(key) }
      puts "Removed #{keys.uniq.size} files uploaded during the run (not committed)."
    end
  end

  def rehearsal_storage?
    service = ActiveStorage::Blob.service

    service.is_a?(ActiveStorage::Service::DiskService) && File.exist?(File.join(service.root, MARKER))
  end

  def storage_label
    service = ActiveStorage::Blob.service

    service.respond_to?(:root) ? "#{service.name} #{service.root}" : service.class.name
  end

  def database_name
    ActiveRecord::Base.connection_db_config.database
  end
end
