import symphony/domain.{
  type ServiceError, type TrackerConfig, UnsupportedTrackerKind,
}
import symphony/tracker.{type Adapter}
import symphony/tracker/file

pub fn create(
  config: TrackerConfig,
  workflow_directory: String,
) -> Result(Adapter, ServiceError) {
  case config.kind {
    "file" -> file.new(config, workflow_directory)
    kind -> Error(UnsupportedTrackerKind(kind))
  }
}
