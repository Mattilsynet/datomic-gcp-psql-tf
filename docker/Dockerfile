FROM eclipse-temurin:21-jre-alpine
ARG datomic_version=1.0.7394

ENV DATOMIC_VERSION $datomic_version
ENV DATOMIC_HOME /opt/datomic-pro-$datomic_version

RUN apk add --no-cache unzip wget

RUN wget https://datomic-pro-downloads.s3.amazonaws.com/${DATOMIC_VERSION}/datomic-pro-${DATOMIC_VERSION}.zip -O /tmp/datomic.zip \
  && unzip /tmp/datomic.zip -d /opt \
  && rm -f /tmp/datomic.zip

WORKDIR $DATOMIC_HOME
RUN echo DATOMIC HOME: $DATOMIC_HOME

VOLUME /etc/datomic
VOLUME /log

ENTRYPOINT ["./bin/transactor", "-Xmx4g", "-Xms4g", "-Ddatomic.printConnectionInfo=true", "/etc/datomic/transactor.properties"]
