// Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// You may not use this file except in compliance with the License.
// A copy of the License is located at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// or in the "license" file accompanying this file. This file is distributed
// on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
// express or implied. See the License for the specific language governing
// permissions and limitations under the License.
//
//  HTTPClient+executeAsyncRetriableWithOutput.swift
//  SmokeHTTPClient
//

import Foundation
import NIO
import NIOHTTP1
import NIOOpenSSL
import NIOTLS
import LoggerAPI

public extension HTTPClient {
    /**
     Helper type that manages the state of a retriable async request.
     */
    private class ExecuteAsyncWithOutputRetriable<InputType, OutputType, InvocationStrategyType>
            where InputType: HTTPRequestInputProtocol, InvocationStrategyType: AsyncResponseInvocationStrategy,
            InvocationStrategyType.OutputType == HTTPResult<OutputType>,
            OutputType: HTTPResponseOutputProtocol {
        let endpointOverride: URL?
        let endpointPath: String
        let httpMethod: HTTPMethod
        let input: InputType
        let outerCompletion: (HTTPResult<OutputType>) -> ()
        let asyncResponseInvocationStrategy: InvocationStrategyType
        let handlerDelegate: HTTPClientChannelInboundHandlerDelegate
        let httpClient: HTTPClient
        let retryConfiguration: HTTPClientRetryConfiguration
        let queue = DispatchQueue.global()
        
        var retriesRemaining: Int
        
        init(endpointOverride: URL?, endpointPath: String, httpMethod: HTTPMethod,
             input: InputType, outerCompletion: @escaping (HTTPResult<OutputType>) -> (),
             asyncResponseInvocationStrategy: InvocationStrategyType,
             handlerDelegate: HTTPClientChannelInboundHandlerDelegate,
             httpClient: HTTPClient,
             retryConfiguration: HTTPClientRetryConfiguration) {
            self.endpointOverride = endpointOverride
            self.endpointPath = endpointPath
            self.httpMethod = httpMethod
            self.input = input
            self.outerCompletion = outerCompletion
            self.asyncResponseInvocationStrategy = asyncResponseInvocationStrategy
            self.handlerDelegate = handlerDelegate
            self.httpClient = httpClient
            self.retryConfiguration = retryConfiguration
            self.retriesRemaining = retryConfiguration.numRetries
        }
        
        func executeAsyncWithOutput() throws {
            // submit the asynchronous request
            _ = try httpClient.executeAsyncWithOutput(endpointOverride: endpointOverride,
                                                      endpointPath: endpointPath, httpMethod: httpMethod,
                                                      input: input, completion: completion,
                                                      asyncResponseInvocationStrategy: asyncResponseInvocationStrategy,
                                                      handlerDelegate: handlerDelegate)
        }
        
        func completion(innerResult: HTTPResult<OutputType>) {
            let result: HTTPResult<OutputType>

            switch innerResult {
            case .error(let error):
                // if there are retries remaining
                if retriesRemaining > 0 {
                    // determine the required interval
                    let retryInterval = Int(retryConfiguration.getRetryInterval(retriesRemaining: retriesRemaining))
                    
                    retriesRemaining -= 1
                    
                    let deadline = DispatchTime.now() + .milliseconds(retryInterval)
                    queue.asyncAfter(deadline: deadline) {
                        do {
                            // execute again
                            try self.executeAsyncWithOutput()
                            return
                        } catch {
                            // its attempting to retry causes an error; complete with the provided error
                            self.outerCompletion(.error(error))
                        }
                    }
                }
                // its an error; complete with the provided error
                result = .error(error)
            case .response:
                result = innerResult
            }

            outerCompletion(result)
        }
    }
    
    /**
     Submits a request that will return a response body to this client asynchronously.
     The completion handler's execution will be scheduled on DispatchQueue.global()
     rather than executing on a thread from SwiftNIO.

     - Parameters:
        - endpointPath: The endpoint path for this request.
        - httpMethod: The http method to use for this request.
        - input: the input body data to send with this request.
        - completion: Completion handler called with the response body or any error.
        - handlerDelegate: the delegate used to customize the request's channel handler.
        - retryConfiguration: the retry configuration for this request.
     */
    public func executeAsyncRetriableWithOutput<InputType, OutputType>(
            endpointOverride: URL? = nil,
            endpointPath: String,
            httpMethod: HTTPMethod,
            input: InputType,
            completion: @escaping (HTTPResult<OutputType>) -> (),
            handlerDelegate: HTTPClientChannelInboundHandlerDelegate,
            retryConfiguration: HTTPClientRetryConfiguration) throws
        where InputType: HTTPRequestInputProtocol, OutputType: HTTPResponseOutputProtocol {
            try executeAsyncRetriableWithOutput(
                endpointOverride: endpointOverride,
                endpointPath: endpointPath,
                httpMethod: httpMethod,
                input: input,
                completion: completion,
                asyncResponseInvocationStrategy: GlobalDispatchQueueAsyncResponseInvocationStrategy<HTTPResult<OutputType>>(),
                handlerDelegate: handlerDelegate,
                retryConfiguration: retryConfiguration)
    }
    
    /**
     Submits a request that will return a response body to this client asynchronously.

     - Parameters:
        - endpointPath: The endpoint path for this request.
        - httpMethod: The http method to use for this request.
        - input: the input body data to send with this request.
        - completion: Completion handler called with the response body or any error.
        - asyncResponseInvocationStrategy: The invocation strategy for the response from this request.
        - handlerDelegate: the delegate used to customize the request's channel handler.
        - retryConfiguration: the retry configuration for this request.
     */
    public func executeAsyncRetriableWithOutput<InputType, OutputType, InvocationStrategyType>(
            endpointOverride: URL? = nil,
            endpointPath: String,
            httpMethod: HTTPMethod,
            input: InputType,
            completion: @escaping (HTTPResult<OutputType>) -> (),
            asyncResponseInvocationStrategy: InvocationStrategyType,
            handlerDelegate: HTTPClientChannelInboundHandlerDelegate,
            retryConfiguration: HTTPClientRetryConfiguration) throws
            where InputType: HTTPRequestInputProtocol, InvocationStrategyType: AsyncResponseInvocationStrategy,
        InvocationStrategyType.OutputType == HTTPResult<OutputType>,
        OutputType: HTTPResponseOutputProtocol {

            let retriable = ExecuteAsyncWithOutputRetriable(
                endpointOverride: endpointOverride, endpointPath: endpointPath,
                httpMethod: httpMethod, input: input, outerCompletion: completion,
                asyncResponseInvocationStrategy: asyncResponseInvocationStrategy,
                handlerDelegate: handlerDelegate, httpClient: self,
                retryConfiguration: retryConfiguration)
            
            try retriable.executeAsyncWithOutput()
    }
}