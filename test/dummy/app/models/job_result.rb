# Rows written by the jobs the integration tests enqueue. Lives in the PRIMARY
# database, so a test that sees one has proof the job actually ran rather than
# proof that a queue row moved.
class JobResult < ApplicationRecord
end
