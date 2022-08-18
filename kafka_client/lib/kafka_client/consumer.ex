defmodule KafkaClient.Consumer do
  def start do
    Port.open(
      {:spawn_executable, System.find_executable("java")},
      args: [
        "-cp",
        "#{Application.app_dir(:kafka_client)}/priv/kafka-client-1.0.jar",
        "com.superology.KafkaConsumer"
      ]
    )
  end
end
