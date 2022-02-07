// Copyright (c) 2022 WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import in_memory_hub.message_queue as mq;
import in_memory_hub.store;
import ballerina/task;
import ballerina/log;
import ballerina/websubhub;

type ClientDetails record {|
    readonly & websubhub:Subscription subscription;
    websubhub:HubClient clientEp;
|};

isolated map<ClientDetails[]> dispatcherClients = {};

# A `task:Job` to run the dispatcher state update.
public isolated class DispatcherJob {
    *task:Job;

    public function execute() {
        error? exception = syncDispatcherState();
        if exception is error {
            log:printError("error occurred while syncing the dispatcher state ", 'error = exception);
        }
    }
}

function syncDispatcherState() returns error? {
    readonly & string[] availableTopics = store:retrieveAvailableTopics();
    lock {
        // remove unavailable topics from the dispatchers
        foreach string dispatcher in dispatcherClients.keys() {
            if availableTopics.indexOf(dispatcher) is () {
                lock {
                    _ = dispatcherClients.removeIfHasKey(dispatcher);
                }
            }
        }
    }

    // update the dispatcher-clients for available topics and start the message consuming for new `topics` 
    foreach string topic in availableTopics {
        boolean isNewTopic = false;
        lock {
            isNewTopic = !dispatcherClients.hasKey(topic);
        }
        if isNewTopic {
            // start the content-dispatcher for the newly added `topic`
            _ = @strand {thread: "any"} start consumeMessages(topic);
        }

        readonly & websubhub:Subscription[]? subscribers = store:retrieveAvailableSubscriptions(topic);
        if subscribers is () {
            lock {
                dispatcherClients[topic] = [];
            }
            continue;
        }
        // TODO: no need to create clients for available subscriptions. hence refactor following logic.
        lock {
            ClientDetails[] clientDetails = [];
            foreach var subscriber in subscribers {
                websubhub:HubClient clientEp = check new (subscriber);
                clientDetails.push({subscription: subscriber, clientEp: clientEp});
            }
            dispatcherClients[topic] = clientDetails;
        }
    }
}

isolated function consumeMessages(string topic) {
    while store:isTopicAvailable(topic) {
        readonly & websubhub:UpdateMessage? message = mq:poll(topic);
        if message is () {
            continue;
        }
        readonly & websubhub:ContentDistributionMessage payload = constructContentDistributionMessage(message);
        lock {
            if dispatcherClients.hasKey(topic) {
                foreach ClientDetails clientDetails in dispatcherClients.get(topic) {
                    readonly & websubhub:Subscription subscription = clientDetails.subscription;
                    // skip invalid subscriptions
                    if !store:isSubscriptionAvailale(subscription.hubTopic, subscription.hubCallback) {
                        continue;
                    }
                    websubhub:HubClient clientEp = clientDetails.clientEp;
                    websubhub:ContentDistributionSuccess|error response = clientEp->notifyContentDistribution(payload);
                    if response is websubhub:SubscriptionDeletedError {
                        store:removeSubscription(subscription.hubTopic, subscription.hubCallback);
                    }
                }
            }
        }
    }
}

isolated function constructContentDistributionMessage(readonly & websubhub:UpdateMessage message) returns readonly & websubhub:ContentDistributionMessage {
    return {
        contentType: message.contentType,
        content: message.content
    };
}
