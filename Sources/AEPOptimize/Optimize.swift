/*
 Copyright 2021 Adobe. All rights reserved.
 This file is licensed to you under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License. You may obtain a copy
 of the License at http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software distributed under
 the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR REPRESENTATIONS
 OF ANY KIND, either express or implied. See the License for the specific language
 governing permissions and limitations under the License.
 */

import AEPCore
import AEPServices

@objc(AEPMobileOptimize)
public class Optimize: NSObject, Extension {
    // MARK: Extension

    public let name = OptimizeConstants.EXTENSION_NAME
    public let friendlyName = OptimizeConstants.FRIENDLY_NAME
    public static let extensionVersion = OptimizeConstants.EXTENSION_VERSION
    public let metadata: [String: String]? = nil
    public let runtime: ExtensionRuntime

    /// Dictionary containing decision propositions currently cached in-memory in the SDK.
    #if DEBUG
        var cachedPropositions: [DecisionScope: Proposition]
    #else
        private(set) var cachedPropositions: [DecisionScope: Proposition]
    #endif

    public required init?(runtime: ExtensionRuntime) {
        self.runtime = runtime
        cachedPropositions = [:]
        super.init()
    }

    public func onRegistered() {
        registerListener(type: EventType.offerDecisioning, source: EventSource.requestContent) { event in
            guard let requestType = event.data?[OptimizeConstants.EventDataKeys.REQUEST_TYPE] as? String else {
                Log.warning(label: OptimizeConstants.LOG_TAG, "Ignoring event! Cannot determine the type of request event.")
                return
            }
            if requestType == OptimizeConstants.EventDataValues.REQUEST_TYPE_UPDATE {
                self.processUpdatePropositions(event: event)
            } else if requestType == OptimizeConstants.EventDataValues.REQUEST_TYPE_GET {
                self.processGetPropositions(event: event)
            }
        }

        registerListener(type: EventType.edge,
                         source: OptimizeConstants.EventSource.EDGE_PERSONALIZATION_DECISIONS,
                         listener: processEdgeResponse(event:))

        registerListener(type: EventType.edge,
                         source: OptimizeConstants.EventSource.EDGE_ERROR_RESPONSE,
                         listener: processEdgeErrorResponse(event:))

        registerListener(type: EventType.offerDecisioning,
                         source: EventSource.requestReset,
                         listener: processClearPropositions(event:))

        // Register listener - Core `resetIdentities()` API dispatches generic identity request reset event.
        registerListener(type: EventType.genericIdentity,
                         source: EventSource.requestReset,
                         listener: processClearPropositions(event:))
    }

    public func onUnregistered() {}

    public func readyForEvent(_ event: Event) -> Bool {
        if event.source == EventSource.requestContent {
            return getSharedState(extensionName: OptimizeConstants.Configuration.EXTENSION_NAME, event: event)?.value != nil
        }
        return true
    }

    // MARK: Event Listeners

    /// Processes the update propositions request event, dispatched with type `EventType.offerDecisioning` and source `EventSource.requestContent`.
    ///
    /// It dispatches an event to the Edge extension to send personalization query request to the Experience Edge network.
    /// - Parameter event: Update propositions request event
    private func processUpdatePropositions(event: Event) {
        guard let decisionScopes: [DecisionScope] = event.getTypedData(for: OptimizeConstants.EventDataKeys.DECISION_SCOPES),
              !decisionScopes.isEmpty
        else {
            Log.debug(label: OptimizeConstants.LOG_TAG, "Decision scopes, in event data, is either not present or empty.")
            return
        }

        let targetDecisionScopes = decisionScopes
            .filter { $0.isValid }
            .compactMap { $0.name }

        if targetDecisionScopes.isEmpty {
            Log.debug(label: OptimizeConstants.LOG_TAG, "No valid decision scopes found for the Edge personalization request!")
            return
        }

        var eventData: [String: Any] = [:]

        // Add query
        eventData[OptimizeConstants.JsonKeys.XDM_QUERY] = [
            OptimizeConstants.JsonKeys.QUERY_PERSONALIZATION: [
                OptimizeConstants.JsonKeys.DECISION_SCOPES: targetDecisionScopes
            ]
        ]

        // Add xdm
        var xdmData: [String: Any] = [
            OptimizeConstants.JsonKeys.XDM_EVENT_TYPE: OptimizeConstants.JsonValues.XDM_EVENT_TYPE_PERSONALIZATION
        ]
        if let additionalXdmData = event.data?[OptimizeConstants.EventDataKeys.XDM] as? [String: Any] {
            xdmData.merge(additionalXdmData) { old, _ in old }
        }
        eventData[OptimizeConstants.JsonKeys.XDM] = xdmData

        // Add data
        if let data = event.data?[OptimizeConstants.EventDataKeys.DATA] as? [String: Any] {
            eventData[OptimizeConstants.JsonKeys.DATA] = data
        }

        // Add datasetId
        if let datasetId = event.data?[OptimizeConstants.EventDataKeys.DATASET_ID] as? String {
            eventData[OptimizeConstants.JsonKeys.DATASET_ID] = datasetId
        }

        let event = Event(name: OptimizeConstants.EventNames.EDGE_PERSONALIZATION_REQUEST,
                          type: EventType.edge,
                          source: EventSource.requestContent,
                          data: eventData)
        dispatch(event: event)
    }

    /// Processes the Edge response event, dispatched with type `EventType.edge` and source `personalization: decisions`.
    ///
    /// It dispatches a personalization notification event with the propositions received from the decisioning services configured behind
    /// Experience Edge network.
    /// - Parameter event: Edge response event.
    private func processEdgeResponse(event: Event) {
        guard let eventType = event.data?[OptimizeConstants.Edge.EVENT_HANDLE] as? String,
              eventType == OptimizeConstants.Edge.EVENT_HANDLE_TYPE_PERSONALIZATION
        else {
            Log.debug(label: OptimizeConstants.LOG_TAG, "Ignoring Edge event, handle type is not personalization:decisions.")
            return
        }

        guard let propositions: [Proposition] = event.getTypedData(for: OptimizeConstants.Edge.PAYLOAD),
              !propositions.isEmpty
        else {
            Log.debug(label: OptimizeConstants.LOG_TAG, "Failed to read Edge response, propositions array is invalid or empty.")
            return
        }

        let propositionsDict = propositions.toDictionary { DecisionScope(name: $0.scope) }

        // Update propositions cache
        cachedPropositions.merge(propositionsDict) { _, new in new }

        let eventData = [OptimizeConstants.EventDataKeys.PROPOSITIONS: propositionsDict].asDictionary()

        let event = Event(name: OptimizeConstants.EventNames.PERSONALIZATION_NOTIFICATION,
                          type: EventType.offerDecisioning,
                          source: EventSource.notification,
                          data: eventData)
        dispatch(event: event)
    }

    /// Processes the Edge error response event, dispatched with type `EventType.edge` and source `com.adobe.eventSource.errorResponseContent`.
    ///
    /// It logs error related information specifying error type along with a detailed message.
    /// - Parameter event: Edge error response event.
    private func processEdgeErrorResponse(event: Event) {
        let errorType = event.data?[OptimizeConstants.Edge.ErrorKeys.TYPE] as? String
        let errorDetail = event.data?[OptimizeConstants.Edge.ErrorKeys.DETAIL] as? String

        let errorString =
            """
            Decisioning Service error, type: \(errorType ?? OptimizeConstants.ERROR_UNKNOWN), \
            detail: \(errorDetail ?? OptimizeConstants.ERROR_UNKNOWN)"
            """

        Log.warning(label: OptimizeConstants.LOG_TAG, errorString)
    }

    /// Processes the get propositions request event, dispatched with type `EventType.offerDecisioning` and source `EventSource.requestContent`.
    ///
    ///  It returns previously cached propositions for the requested decision scopes. Any decision scope(s) not already present in the cache are ignored.
    /// - Parameter event: Get propositions request event
    private func processGetPropositions(event: Event) {
        guard let decisionScopes: [DecisionScope] = event.getTypedData(for: OptimizeConstants.EventDataKeys.DECISION_SCOPES),
              !decisionScopes.isEmpty
        else {
            Log.debug(label: OptimizeConstants.LOG_TAG, "Decision scopes, in event data, is either not present or empty.")
            dispatch(event: event.createErrorResponseEvent(AEPError.invalidRequest))
            return
        }

        let propositionsDict = cachedPropositions.filter { decisionScopes.contains($0.key) }

        let eventData = [OptimizeConstants.EventDataKeys.PROPOSITIONS: propositionsDict].asDictionary()

        let responseEvent = event.createResponseEvent(
            name: OptimizeConstants.EventNames.PERSONALIZATION_RESPONSE,
            type: EventType.offerDecisioning,
            source: EventSource.responseContent,
            data: eventData
        )
        dispatch(event: responseEvent)
    }

    /// Clears propositions cached in-memory in the extension.
    ///
    /// This method is also invoked upon Core`resetIdentities` to clear the propositions cached locally.
    /// - Parameter event: Personalization request reset event.
    private func processClearPropositions(event _: Event) {
        // Clear propositions cache
        cachedPropositions.removeAll()
    }
}